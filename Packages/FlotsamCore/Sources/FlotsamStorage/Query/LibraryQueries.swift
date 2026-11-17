import FlotsamBase
import Foundation
import GRDB

/// The query layer (FR-007-18): every Library and Shelf read goes through here, so filter, search and sort have one
/// implementation. Reads run in a single GRDB read transaction, so a page and its count describe the same snapshot.
///
/// Search is a substring scan of the pre-normalised `item.searchText` (`instr`, AND over tokens), which gives exactly
/// the FR-003-09 result set. Whether to replace it with an FTS5 trigram index is spike S-1's call (TASK-004); the
/// public API does not change either way.
extension FlotsamDatabase {
    // MARK: Pages

    /// One page of `query` (200 rows) and the size of the whole result set. Failure is `STO-DB-004` (Library shows an
    /// inline Retry).
    public func items(matching query: LibraryQuery) async -> FlotsamResult<ItemPage> {
        do {
            return .success(try await pool.read { db in try Self.page(db, query: query) })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }

    /// Count of `filter` combined with `text`, by the same predicate the page uses (the "{n} items" footer).
    public func count(filter: LibraryFilter, text: String = "") async -> FlotsamResult<Int> {
        do {
            return .success(try await pool.read { db in
                try Self.count(db, selection: Selection(filter: filter, text: text))
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }

    /// Sidebar rows and counts (FRD-003 FR-003-12). Each count is the page query's own predicate, never a second
    /// hand-written one, so a row's number always equals what selecting that row lists.
    public func sidebarCounts() async -> FlotsamResult<SidebarCounts> {
        do {
            return .success(try await pool.read { db in try Self.sidebar(db) })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }

    // MARK: Selection (the one definition of filter + search)

    /// A WHERE clause over `item` plus its arguments.
    struct Selection {
        let sql: String
        let arguments: StatementArguments

        init(filter: LibraryFilter, text: String) {
            var clauses: [String] = []
            var arguments = StatementArguments()
            switch filter {
            case .all: break
            case .pinned: clauses.append("pinned = 1")
            case .kind(let kind):
                clauses.append("kind = ?")
                arguments += [kind.rawValue]
            case .tag(let tagId):
                clauses.append("id IN (SELECT itemId FROM itemTag WHERE tagId = ?)")
                arguments += [tagId]
            case .sourceApp(let identity):
                clauses.append("\(FlotsamDatabase.sourceKeySQL) = ?")
                arguments += [FlotsamDatabase.sourceKey(identity)]
            }
            // `searchText` is already normalised, and tokens go through the same normaliser (FR-003-09).
            for token in SearchNormalizer.tokens(from: text) {
                clauses.append("instr(searchText, ?) > 0")
                arguments += [token]
            }
            sql = clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
            self.arguments = arguments
        }
    }

    // MARK: Source-app identity

    private static let anotherDeviceKey = "#another-device"
    private static let unknownKey = "#unknown"

    /// Groups items by source: bundle identifier, else the "Another device" bucket, else "Unknown" (FRD-004
    /// FR-004-10). Filtering and the sidebar's app counts both use this expression, so the two cannot disagree.
    /// The name literal is a compile-time constant with quotes doubled, never user input.
    private static var sourceKeySQL: String {
        let name = SourceApp.anotherDeviceName.replacingOccurrences(of: "'", with: "''")
        return """
            CASE WHEN NULLIF(sourceBundleId, '') IS NOT NULL THEN sourceBundleId \
            WHEN sourceName = '\(name)' THEN '\(anotherDeviceKey)' ELSE '\(unknownKey)' END
            """
    }

    private static func sourceKey(_ identity: SourceAppIdentity) -> String {
        switch identity {
        case .bundle(let id): id
        case .anotherDevice: anotherDeviceKey
        case .unknown: unknownKey
        }
    }

    private static func sourceIdentity(fromKey key: String) -> SourceAppIdentity {
        switch key {
        case anotherDeviceKey: .anotherDevice
        case unknownKey: .unknown
        default: .bundle(key)
        }
    }

    // MARK: Order

    /// Every sort ends `lastCopiedAt` descending then `id`, so equal keys order the same way on every load (FR-004-12).
    private static func orderSQL(_ sort: LibrarySort) -> String {
        switch sort {
        case .recent: "lastCopiedAt DESC, id ASC"
        case .oldest: "lastCopiedAt ASC, id ASC"
        case .mostUsed: "pasteCount DESC, lastCopiedAt DESC, id ASC"
        // Alphabetical needs a locale-aware comparison SQLite cannot do; it is ordered in Swift (`alphabeticalIds`).
        case .alphabetical: "lastCopiedAt DESC, id ASC"
        }
    }

    // MARK: Reading

    private static func count(_ db: Database, selection: Selection) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE \(selection.sql)", arguments: selection.arguments) ?? 0
    }

    private static func page(_ db: Database, query: LibraryQuery) throws -> ItemPage {
        let selection = Selection(filter: query.filter, text: query.text)
        let total = try count(db, selection: selection)
        let offset = query.page * LibraryQuery.pageSize

        let ids: [String]
        var cores: [RowCore]
        if query.sort == .alphabetical {
            // 10,000 rows of short keys is cheap, and it is the only way to honour the locale-aware order.
            let all = try fetchCores(db, whereSQL: selection.sql, arguments: selection.arguments)
            let ordered = all.sorted(by: alphabetical)
            let slice = ordered.dropFirst(offset).prefix(LibraryQuery.pageSize)
            ids = slice.map(\.id)
            cores = Array(slice)
        } else {
            ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM item WHERE \(selection.sql) ORDER BY \(orderSQL(query.sort)) LIMIT ? OFFSET ?",
                arguments: selection.arguments + [LibraryQuery.pageSize, offset])
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let byId = Dictionary(
                uniqueKeysWithValues: try fetchCores(
                    db, whereSQL: "id IN (\(placeholders))", arguments: StatementArguments(ids)
                ).map { ($0.id, $0) })
            cores = ids.compactMap { byId[$0] }
        }

        // One query for every tag of the page, not one per row.
        let tags = try tagNames(db, itemIds: ids)
        let rows = cores.compactMap { $0.row(tagNames: tags[$0.id] ?? []) }
        return ItemPage(rows: rows, totalCount: total, page: query.page)
    }

    private static func alphabetical(_ lhs: RowCore, _ rhs: RowCore) -> Bool {
        switch lhs.primaryLine.localizedStandardCompare(rhs.primaryLine) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame:
            if lhs.lastCopiedAt != rhs.lastCopiedAt { return lhs.lastCopiedAt > rhs.lastCopiedAt }
            return lhs.id < rhs.id
        }
    }

    /// An item's columns with its primary line already built, before tags are attached.
    private struct RowCore {
        let id: String
        let kind: String
        let lastCopiedAt: Int64
        let pasteCount: Int
        let primaryLine: String
        let sourceName: String?
        let isPinned: Bool
        let hasTrigger: Bool
        let hasShortcut: Bool
        let pixelWidth: Int?
        let pixelHeight: Int?
        let memberCount: Int
        let byteSize: Int64

        func row(tagNames: [String]) -> ItemRow? {
            guard let uuid = UUID(uuidString: id), let kind = ItemKind(rawValue: kind) else { return nil }
            return ItemRow(
                id: uuid, kind: kind, lastCopiedAt: Date(epochMillis: lastCopiedAt), pasteCount: pasteCount,
                primaryLine: primaryLine, sourceName: sourceName, tagNames: tagNames, isPinned: isPinned,
                hasTrigger: hasTrigger, hasShortcut: hasShortcut, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                memberCount: memberCount, byteSize: byteSize)
        }
    }

    /// Plain text is cut in SQL: a 5 MB text item must not be read in full to show 140 characters.
    private static let primaryTextReadLimit = 1_000

    private static func fetchCores(_ db: Database, whereSQL: String, arguments: StatementArguments) throws -> [RowCore] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, kind, lastCopiedAt, pasteCount, substr(plainText, 1, ?) AS text, sourceName, pinned,
                       "trigger" IS NOT NULL AS hasTrigger, hotkeyCode IS NOT NULL AS hasShortcut,
                       pixelWidth, pixelHeight, byteSize,
                       (SELECT COUNT(*) FROM bundleMember WHERE bundleMember.itemId = item.id) AS memberCount
                FROM item WHERE \(whereSQL)
                """,
            arguments: [primaryTextReadLimit] + arguments)

        // The first names of every selected member list in one query (no per-row lookups).
        var names: [String: [String]] = [:]
        let members = try Row.fetchAll(
            db,
            sql: """
                SELECT itemId, path FROM bundleMember
                WHERE ordinal < ? AND itemId IN (SELECT id FROM item WHERE \(whereSQL))
                ORDER BY itemId, ordinal
                """,
            arguments: [PrimaryLine.bundleNameLimit] + arguments)
        for member in members {
            let itemId: String = member["itemId"]
            let path: String = member["path"]
            names[itemId, default: []].append(URL(fileURLWithPath: path).lastPathComponent)
        }

        return rows.map { row in
            let id: String = row["id"]
            let kind: String = row["kind"]
            let memberCount: Int = row["memberCount"]
            return RowCore(
                id: id, kind: kind, lastCopiedAt: row["lastCopiedAt"], pasteCount: row["pasteCount"],
                primaryLine: PrimaryLine.text(
                    kind: ItemKind(rawValue: kind) ?? .text, plainText: row["text"], pixelWidth: row["pixelWidth"],
                    pixelHeight: row["pixelHeight"], memberCount: memberCount, memberNames: names[id] ?? []),
                sourceName: row["sourceName"], isPinned: row["pinned"] == 1, hasTrigger: row["hasTrigger"],
                hasShortcut: row["hasShortcut"], pixelWidth: row["pixelWidth"], pixelHeight: row["pixelHeight"],
                memberCount: memberCount, byteSize: row["byteSize"])
        }
    }

    private static func tagNames(_ db: Database, itemIds: [String]) throws -> [String: [String]] {
        guard !itemIds.isEmpty else { return [:] }
        let placeholders = itemIds.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT itemTag.itemId AS itemId, tag.name AS name FROM itemTag JOIN tag ON tag.id = itemTag.tagId
                WHERE itemTag.itemId IN (\(placeholders)) ORDER BY itemTag.itemId, tag.name COLLATE NOCASE
                """,
            arguments: StatementArguments(itemIds))
        var result: [String: [String]] = [:]
        for row in rows { result[row["itemId"], default: []].append(row["name"]) }
        return result
    }

    // MARK: Sidebar

    /// Apps shown in the sidebar (FR-003-12).
    private static let sidebarAppLimit = 15

    private static func sidebar(_ db: Database) throws -> SidebarCounts {
        func counted(_ filter: LibraryFilter) throws -> Int {
            try count(db, selection: Selection(filter: filter, text: ""))
        }
        var kinds: [ItemKind: Int] = [:]
        for kind in ItemKind.allCases {
            let n = try counted(.kind(kind))
            if n > 0 { kinds[kind] = n }
        }
        var tags: [SidebarCounts.TagCount] = []
        for tag in try Row.fetchAll(db, sql: "SELECT id, name, color FROM tag ORDER BY name COLLATE NOCASE") {
            let id: Int64 = tag["id"]
            tags.append(SidebarCounts.TagCount(id: id, name: tag["name"], color: tag["color"], count: try counted(.tag(id))))
        }
        // Grouped by the same key expression the sourceApp filter compares against.
        let apps = try Row.fetchAll(
            db,
            sql: """
                SELECT \(sourceKeySQL) AS key, MAX(sourceName) AS name, COUNT(*) AS n FROM item
                GROUP BY key ORDER BY n DESC, key ASC LIMIT ?
                """,
            arguments: [sidebarAppLimit]
        ).map { row in
            SidebarCounts.AppCount(identity: sourceIdentity(fromKey: row["key"]), name: row["name"], count: row["n"])
        }
        return SidebarCounts(all: try counted(.all), pinned: try counted(.pinned), kinds: kinds, tags: tags, apps: apps)
    }
}
