import FlotsamBase
import Foundation
import GRDB

extension FlotsamDatabase {
    /// FR-004-11: replaces a bundle with one item per member, in one transaction. Returns the new item ids in member
    /// order, or an empty list when the bundle no longer exists. An item that is not a bundle is a caller bug
    /// (`SYS-INT-001`): the UI offers Ungroup for a single bundle only.
    ///
    /// Each new item: kind and `contentKey` from `classifiers` (the capture rules for a single file, so a later copy
    /// of the same file dedupes against it); `createdAt` and source copied from the bundle; `lastCopiedAt` the bundle's
    /// minus the member's zero-based index in milliseconds, so Recent lists the members in their original order; the
    /// bundle's tags. Note, pin, trigger and hotkey stay behind and go with the bundle. No dedupe against other items.
    ///
    /// The bundle goes through the shared delete (`deleteRows`), so its blobs and thumbnails are removed after commit
    /// exactly as for any delete (FR-007-15). If any insert fails nothing changes and the bundle is untouched.
    public func ungroup(bundle id: UUID, classifiers: ItemClassifiers) async -> FlotsamResult<[UUID]> {
        let now = clock.now().epochMillis
        let result: FlotsamResult<(created: [UUID], removed: [DeletedItem])> = await organizeWrite { db in
            let key = id.uuidString
            guard let bundle = try Row.fetchOne(
                db, sql: "SELECT kind, createdAt, lastCopiedAt, sourceBundleId, sourceName FROM item WHERE id = ?",
                arguments: [key]) else { return ([], []) }
            guard (bundle["kind"] as String) == ItemKind.bundle.rawValue else {
                throw OrganizeRejection(error: FlotsamError(.sysInt001, "Ungroup was asked for an item that is not a bundle", context: [.itemId: .id(id)]))
            }
            let createdAt: Int64 = bundle["createdAt"]
            let lastCopiedAt: Int64 = bundle["lastCopiedAt"]
            let members = try Row.fetchAll(
                db, sql: "SELECT path, bookmark, isDirectory FROM bundleMember WHERE itemId = ? ORDER BY ordinal", arguments: [key])
            let tagIds = try Int64.fetchAll(db, sql: "SELECT tagId FROM itemTag WHERE itemId = ? ORDER BY tagId", arguments: [key])

            var created: [UUID] = []
            for (index, member) in members.enumerated() {
                let path: String = member["path"]
                let isDirectory: Bool = member["isDirectory"]
                let classification = classifiers.fileMember(path, isDirectory)
                let newId = UUID()
                let newKey = newId.uuidString
                try db.execute(
                    sql: """
                        INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, sourceBundleId, sourceName, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        newKey, classification.kind.rawValue, createdAt, lastCopiedAt - Int64(index), classification.contentKey,
                        bundle["sourceBundleId"] as String?, bundle["sourceName"] as String?, now,
                    ])
                try db.execute(
                    sql: "INSERT INTO bundleMember (itemId, ordinal, path, bookmark, isDirectory) VALUES (?, 0, ?, ?, ?)",
                    arguments: [newKey, path, member["bookmark"] as Data?, isDirectory])
                for tagId in tagIds {
                    try db.execute(sql: "INSERT INTO itemTag (itemId, tagId) VALUES (?, ?)", arguments: [newKey, tagId])
                }
                try SearchIndex.refresh(db, itemId: newKey)
                created.append(newId)
            }
            return (created, try Self.deleteRows(db, ids: [id], guard: nil))
        }
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let done):
            guard !done.removed.isEmpty else { return .success([]) }
            publishOrganizeChange()
            _ = await finishDeletion(done.removed)
            return .success(done.created)
        }
    }
}
