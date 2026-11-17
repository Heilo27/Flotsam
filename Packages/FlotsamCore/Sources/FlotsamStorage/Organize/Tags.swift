import FlotsamBase
import Foundation
import GRDB

/// FR-004-02: what a tag name may be, in one place. Create, rename and the tag editor's "Create tag" row all ask here.
enum TagNameRule {
    /// The stored name: trimmed, 1 to 32 characters, no control characters. nil is `ORG-VAL-001`.
    static func validated(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= OrganizeLimits.maxTagNameCharacters else { return nil }
        guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return name
    }

    /// Unique case- and diacritic-insensitively, with the same folding search uses (FR-003-09).
    static func key(_ name: String) -> String { SearchNormalizer.normalize(name) }
}

extension FlotsamDatabase {
    // MARK: Tag records (FR-004-02, FR-004-04)

    /// Creates a tag and returns its id. `ORG-VAL-001` for a bad or duplicate name, `ORG-LIM-002` at 100 tags.
    public func createTag(name: String, color: TagColor = .default) async -> FlotsamResult<Int64> {
        let now = clock.now().epochMillis
        let result: FlotsamResult<Int64> = await organizeWrite { db in
            try Self.insertTag(db, name: name, color: color, now: now)
        }
        if case .success = result { publishOrganizeChange() }
        return result
    }

    /// FR-004-03: Return in the editor's field with no exact match creates the tag and applies it to the selection,
    /// as one action. A failure to apply (`ORG-LIM-001`) leaves no new tag behind.
    public func createTagAndApply(name: String, color: TagColor = .default, to ids: [UUID]) async -> FlotsamResult<Int64> {
        let now = clock.now().epochMillis
        let result: FlotsamResult<Int64> = await organizeWrite { db in
            let tagId = try Self.insertTag(db, name: name, color: color, now: now)
            try Self.link(db, tagId: tagId, items: Self.unique(ids), now: now)
            return tagId
        }
        if case .success = result { publishOrganizeChange() }
        return result
    }

    /// Renames in place: every item carrying the tag shows the new name and none moves (FR-004-04). Renaming a tag to
    /// a different capitalisation or accent of its own name is allowed. Returns false when the tag no longer exists.
    public func renameTag(id: Int64, to name: String) async -> FlotsamResult<Bool> {
        let result: FlotsamResult<Bool> = await organizeWrite { db in
            guard let stored = TagNameRule.validated(name) else { throw OrganizeRejection(error: Self.badTagName) }
            guard try Self.tagExists(db, id: id) else { return false }
            try Self.rejectDuplicate(db, name: stored, excluding: id)
            try db.execute(sql: "UPDATE tag SET name = ? WHERE id = ?", arguments: [stored, id])
            try Self.reindexItems(db, tagId: id)
            return true
        }
        if case .success(true) = result { publishOrganizeChange() }
        return result
    }

    /// Changes the colour of a tag for all its items at once. Returns false when the tag no longer exists.
    public func recolorTag(id: Int64, to color: TagColor) async -> FlotsamResult<Bool> {
        let result: FlotsamResult<Bool> = await organizeWrite { db in
            try db.execute(sql: "UPDATE tag SET color = ? WHERE id = ?", arguments: [color.rawValue, id])
            return db.changesCount > 0
        }
        if case .success(true) = result { publishOrganizeChange() }
        return result
    }

    /// Removes the tag from every item and deletes it; the items stay (FR-004-04). Returns how many items it was on
    /// (0 when the tag no longer exists), which is the `{n}` in the confirmation the caller already showed.
    public func deleteTag(id: Int64) async -> FlotsamResult<Int> {
        let result: FlotsamResult<Int> = await organizeWrite { db in
            let itemIds = try String.fetchAll(db, sql: "SELECT itemId FROM itemTag WHERE tagId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [id])
            for itemId in itemIds { try SearchIndex.refresh(db, itemId: itemId) }
            return itemIds.count
        }
        if case .success = result { publishOrganizeChange() }
        return result
    }

    // MARK: Assignment (FR-004-03)

    /// For the tag editor's check state: how many of `ids` carry each tag. A tag whose count is 0 is unchecked, equal
    /// to the number of existing items is checked, anything between is mixed. Tags on none of the items are absent.
    public func tagMembership(of ids: [UUID]) async -> FlotsamResult<[Int64: Int]> {
        let keys = Self.unique(ids).map(\.uuidString)
        guard !keys.isEmpty else { return .success([:]) }
        do {
            return .success(try await pool.read { db in
                var counts: [Int64: Int] = [:]
                for chunk in keys.chunked(into: 500) {
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT tagId, COUNT(*) AS n FROM itemTag
                            WHERE itemId IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))
                            GROUP BY tagId
                            """,
                        arguments: StatementArguments(chunk))
                    for row in rows { counts[row["tagId"], default: 0] += row["n"] as Int }
                }
                return counts
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }

    /// Toggling a tag in the editor: when every selected item has it the tag comes off all of them, otherwise
    /// (none or mixed) it goes on all of them. Decided inside the transaction, like pin. Returns whether the tag is
    /// now applied. `ORG-LIM-001` when an item would pass 10 tags; nothing changes then.
    public func toggleTag(id: Int64, on ids: [UUID]) async -> FlotsamResult<Bool> {
        let now = clock.now().epochMillis
        let result: FlotsamResult<Bool> = await organizeWrite { db in
            guard try Self.tagExists(db, id: id) else { return false }
            let existing = try Self.existingItems(db, Self.unique(ids))
            guard !existing.isEmpty else { return false }
            let withTag = try Self.itemsWithTag(db, tagId: id, among: existing)
            if withTag.count == existing.count {
                try Self.unlink(db, tagId: id, items: existing, now: now)
                return false
            }
            try Self.link(db, tagId: id, items: existing, now: now)
            return true
        }
        if case .success = result { publishOrganizeChange() }
        return result
    }

    // MARK: Transaction pieces

    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static var badTagName: FlotsamError { FlotsamError(.orgVal001, "Tag name is empty, too long, has control characters or is taken") }

    private static func tagExists(_ db: Database, id: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM tag WHERE id = ?)", arguments: [id]) ?? false
    }

    private static func insertTag(_ db: Database, name: String, color: TagColor, now: Int64) throws -> Int64 {
        guard let stored = TagNameRule.validated(name) else { throw OrganizeRejection(error: badTagName) }
        try rejectDuplicate(db, name: stored, excluding: nil)
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0
        guard total < OrganizeLimits.maxTags else {
            throw OrganizeRejection(error: FlotsamError(.orgLim002, "Tag ceiling reached", context: [.count: .int(total)]))
        }
        try db.execute(
            sql: "INSERT INTO tag (name, color, createdAt) VALUES (?, ?, ?)", arguments: [stored, color.rawValue, now])
        return db.lastInsertedRowID
    }

    /// The tag table is tiny (at most 100 rows), so the diacritic-insensitive comparison is done here with the one
    /// search folding rather than in SQL, where `COLLATE NOCASE` would cover case only.
    private static func rejectDuplicate(_ db: Database, name: String, excluding id: Int64?) throws {
        let wanted = TagNameRule.key(name)
        let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM tag")
        for row in rows where (row["id"] as Int64) != id && TagNameRule.key(row["name"]) == wanted {
            throw OrganizeRejection(error: badTagName)
        }
    }

    private static func existingItems(_ db: Database, _ ids: [UUID]) throws -> [UUID] {
        try ids.filter { try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM item WHERE id = ?)", arguments: [$0.uuidString]) ?? false }
    }

    private static func itemsWithTag(_ db: Database, tagId: Int64, among ids: [UUID]) throws -> [UUID] {
        try ids.filter {
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM itemTag WHERE tagId = ? AND itemId = ?)",
                arguments: [tagId, $0.uuidString]) ?? false
        }
    }

    /// Puts the tag on every listed item that exists and lacks it. All or nothing: one item over the per-item ceiling
    /// rejects the whole action (`ORG-LIM-001`) and the transaction rolls back.
    private static func link(_ db: Database, tagId: Int64, items ids: [UUID], now: Int64) throws {
        for id in ids {
            let key = id.uuidString
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM item WHERE id = ?)", arguments: [key]) == true else { continue }
            let already = try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM itemTag WHERE tagId = ? AND itemId = ?)", arguments: [tagId, key]) ?? false
            if already { continue }
            let held = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM itemTag WHERE itemId = ?", arguments: [key]) ?? 0
            guard held < OrganizeLimits.maxTagsPerItem else {
                throw OrganizeRejection(error: FlotsamError(.orgLim001, "Item already has the maximum number of tags", context: [.itemId: .id(id)]))
            }
            try db.execute(sql: "INSERT INTO itemTag (itemId, tagId) VALUES (?, ?)", arguments: [key, tagId])
            try db.execute(sql: "UPDATE item SET updatedAt = ? WHERE id = ?", arguments: [now, key])
            try SearchIndex.refresh(db, itemId: key)
        }
    }

    private static func unlink(_ db: Database, tagId: Int64, items ids: [UUID], now: Int64) throws {
        for id in ids {
            let key = id.uuidString
            try db.execute(sql: "DELETE FROM itemTag WHERE itemId = ? AND tagId = ?", arguments: [key, tagId])
            if db.changesCount > 0 {
                try db.execute(sql: "UPDATE item SET updatedAt = ? WHERE id = ?", arguments: [now, key])
                try SearchIndex.refresh(db, itemId: key)
            }
        }
    }

    private static func reindexItems(_ db: Database, tagId: Int64) throws {
        for itemId in try String.fetchAll(db, sql: "SELECT itemId FROM itemTag WHERE tagId = ?", arguments: [tagId]) {
            try SearchIndex.refresh(db, itemId: itemId)
        }
    }
}
