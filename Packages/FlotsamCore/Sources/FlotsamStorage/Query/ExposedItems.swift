import FlotsamBase
import Foundation
import GRDB

/// An item as an outside reader (an approved MCP client, FRD-010) may see it: text and metadata only. No blob, no
/// thumbnail, no file path, no hotkey, no secure content.
public struct ExposedItem: Sendable, Equatable {
    public let id: UUID
    public let kind: ItemKind
    /// The item's text, cut to the caller's `textLimit` characters; nil for an item with no text (an image, a file).
    public let text: String?
    public let isTextTruncated: Bool
    public let note: String?
    public let tags: [String]
    public let sourceName: String?
    public let lastCopiedAt: Date
    public let copyCount: Int
    public let byteSize: Int64
    /// File names only (never paths) of a file, folder or bundle item, capped at `ExposureLimits.maxFileNames`.
    public let fileNames: [String]
}

/// The bounds on what one MCP call returns, so a client cannot pull the whole library in one request (FR-010-09).
public enum ExposureLimits {
    public static let defaultResults = 20
    public static let maxResults = 50
    /// Characters of an item's text in a search result.
    public static let previewCharacters = 300
    /// Characters of an item's text from `get_item`.
    public static let fullTextCharacters = 20_000
    public static let maxFileNames = 50
}

/// The read side for outside readers (FRD-010). It is a second door into `item`, so it has exactly one gate
/// (`exposureGate`) and every query here goes through it: nothing in this file selects from `item` without it.
extension FlotsamDatabase {
    /// The visibility gate (FR-010-08): a secure item is never visible, whatever its row says elsewhere (the flag and the
    /// ciphertext are each enough to hide it), and neither is an item copied from an ignored app. Ignored apps are
    /// dropped at capture, but a copy stored before the user added the app to the list is still in the library, so the
    /// gate also checks them at read time. Secure rows are not in `searchText` either (FR-007-03), so a search cannot
    /// match them even before this gate runs.
    static func exposureGate(ignoredApps: Set<String>) -> Selection {
        var sql = "isSecure = 0 AND secureCiphertext IS NULL"
        var arguments = StatementArguments()
        let ignored = ignoredApps.sorted()
        if !ignored.isEmpty {
            let placeholders = ignored.map { _ in "?" }.joined(separator: ",")
            sql += " AND (NULLIF(sourceBundleId, '') IS NULL OR sourceBundleId NOT IN (\(placeholders)))"
            arguments += StatementArguments(ignored)
        }
        return Selection(sql: sql, arguments: arguments)
    }

    /// Newest-first items matching `text` (the Library's own search: `Selection`) and, if given, `kind`, behind the gate.
    /// An empty `text` lists the most recent. Failure is `STO-DB-004`, as for every read (FR-007-18).
    public func exposedItems(
        matching text: String, kind: ItemKind?, limit: Int, textLimit: Int, ignoredApps: Set<String>
    ) async -> FlotsamResult<[ExposedItem]> {
        let selection = Selection(filter: kind.map { .kind($0) } ?? .all, text: text)
        let gate = Self.exposureGate(ignoredApps: ignoredApps)
        let bounded = min(max(limit, 1), ExposureLimits.maxResults)
        do {
            return .success(try await pool.read { db in
                try Self.fetchExposed(
                    db, whereSQL: "(\(selection.sql)) AND \(gate.sql)", arguments: selection.arguments + gate.arguments,
                    limit: bounded, textLimit: textLimit)
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }

    /// One item by id behind the same gate: nil for an id that does not exist and for one the gate hides, so the two
    /// cannot be told apart.
    public func exposedItem(id: UUID, textLimit: Int, ignoredApps: Set<String>) async -> FlotsamResult<ExposedItem?> {
        let gate = Self.exposureGate(ignoredApps: ignoredApps)
        do {
            return .success(try await pool.read { db in
                try Self.fetchExposed(
                    db, whereSQL: "id = ? AND \(gate.sql)", arguments: StatementArguments([id.uuidString]) + gate.arguments,
                    limit: 1, textLimit: textLimit
                ).first
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }

    /// Rows, tags and file names for one result set in three queries, never one per row.
    private static func fetchExposed(
        _ db: Database, whereSQL: String, arguments: StatementArguments, limit: Int, textLimit: Int
    ) throws -> [ExposedItem] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, kind, substr(plainText, 1, ?) AS text, length(plainText) AS textLength, note, sourceName,
                       lastCopiedAt, copyCount, byteSize
                FROM item WHERE \(whereSQL) ORDER BY lastCopiedAt DESC, id ASC LIMIT ?
                """,
            arguments: StatementArguments([textLimit]) + arguments + [limit])
        let ids: [String] = rows.map { $0["id"] }
        let tags = try tagNames(db, itemIds: ids)
        let names = try memberNames(db, itemIds: ids)
        return rows.compactMap { row in
            let rawId: String = row["id"]
            let rawKind: String = row["kind"]
            guard let uuid = UUID(uuidString: rawId), let kind = ItemKind(rawValue: rawKind) else { return nil }
            let textLength: Int? = row["textLength"]
            let copiedAt: Int64 = row["lastCopiedAt"]
            return ExposedItem(
                id: uuid, kind: kind, text: row["text"], isTextTruncated: (textLength ?? 0) > textLimit, note: row["note"],
                tags: tags[rawId] ?? [], sourceName: row["sourceName"],
                lastCopiedAt: Date(timeIntervalSince1970: Double(copiedAt) / 1000), copyCount: row["copyCount"],
                byteSize: row["byteSize"], fileNames: names[rawId] ?? [])
        }
    }

    private static func memberNames(_ db: Database, itemIds: [String]) throws -> [String: [String]] {
        guard !itemIds.isEmpty else { return [:] }
        let placeholders = itemIds.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(
            db, sql: "SELECT itemId, path FROM bundleMember WHERE itemId IN (\(placeholders)) ORDER BY itemId, ordinal",
            arguments: StatementArguments(itemIds))
        var result: [String: [String]] = [:]
        for row in rows {
            let id: String = row["itemId"]
            guard (result[id]?.count ?? 0) < ExposureLimits.maxFileNames else { continue }
            let path: String = row["path"]
            result[id, default: []].append(URL(fileURLWithPath: path).lastPathComponent)
        }
        return result
    }
}
