import FlotsamBase
import Foundation
import GRDB

extension FlotsamDatabase {
    /// FR-004-15: replaces two or more file, folder or bundle items with one bundle holding all their members, in one
    /// transaction. Returns the new bundle's id, or nil when fewer than two of `ids` still exist.
    ///
    /// Only items that reference files can be grouped, because a bundle holds files by reference (FR-001-12). Anything
    /// else in the selection, fewer than two items, or more than `BundleLimits.maxMembers` members in all is
    /// `ORG-VAL-004` and nothing changes. Members keep the order of `ids` and, inside a bundle, their own order.
    ///
    /// The new bundle: kind and `contentKey` from `classifiers.fileSet` (what a copy of the same files would be, so a
    /// later copy dedupes against it); `createdAt` and `lastCopiedAt` now; the source app when every item has the same
    /// one; the union of the items' tags up to `OrganizeLimits.maxTagsPerItem`. Notes, pins, triggers and hotkeys stay
    /// behind and go with the items (the same rule as Ungroup, FR-004-11). No dedupe against other items.
    ///
    /// The items go through the shared delete (`deleteRows`), so their blobs and thumbnails are removed after commit
    /// exactly as for any delete (FR-007-15). If any step fails nothing changes.
    public func groupIntoBundle(ids: [UUID], classifiers: ItemClassifiers) async -> FlotsamResult<UUID?> {
        let now = clock.now().epochMillis
        var seen = Set<UUID>()
        let requested = ids.filter { seen.insert($0).inserted }
        let result: FlotsamResult<(created: UUID?, removed: [DeletedItem])> = await organizeWrite { db in
            var items: [(id: UUID, row: Row)] = []
            for id in requested {
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT kind, sourceBundleId, sourceName FROM item WHERE id = ?", arguments: [id.uuidString])
                else { continue }
                items.append((id, row))
            }
            guard items.count >= 2 else { throw OrganizeRejection(error: Self.badGroupSelection(count: items.count)) }
            for item in items {
                let kind = ItemKind(rawValue: item.row["kind"] as String)
                guard kind?.referencesFiles == true else { throw OrganizeRejection(error: Self.badGroupSelection(count: items.count)) }
            }

            var members: [Row] = []
            for item in items {
                members += try Row.fetchAll(
                    db, sql: "SELECT path, bookmark, isDirectory FROM bundleMember WHERE itemId = ? ORDER BY ordinal",
                    arguments: [item.id.uuidString])
            }
            guard members.count >= 2, members.count <= IngestLimits.maxBundleMembers else {
                throw OrganizeRejection(error: Self.badGroupSelection(count: items.count))
            }
            guard let fileSet = classifiers.fileSet else {
                throw OrganizeRejection(error: FlotsamError(.sysInt001, "Group was asked without a file-set classifier"))
            }
            let classification = fileSet(members.map { $0["path"] as String })

            let sourceIds = Set(items.map { $0.row["sourceBundleId"] as String? })
            let sourceNames = Set(items.map { $0.row["sourceName"] as String? })
            let sameSource = sourceIds.count == 1 && sourceNames.count == 1
            let bundleId = UUID()
            let key = bundleId.uuidString
            try db.execute(
                sql: """
                    INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, sourceBundleId, sourceName, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    key, classification.kind.rawValue, now, now, classification.contentKey,
                    sameSource ? items[0].row["sourceBundleId"] as String? : nil,
                    sameSource ? items[0].row["sourceName"] as String? : nil, now,
                ])
            for (ordinal, member) in members.enumerated() {
                try db.execute(
                    sql: "INSERT INTO bundleMember (itemId, ordinal, path, bookmark, isDirectory) VALUES (?, ?, ?, ?, ?)",
                    arguments: [key, ordinal, member["path"] as String, member["bookmark"] as Data?, member["isDirectory"] as Bool])
            }
            let marks = items.map { _ in "?" }.joined(separator: ",")
            let tagIds = try Int64.fetchAll(
                db, sql: "SELECT DISTINCT tagId FROM itemTag WHERE itemId IN (\(marks)) ORDER BY tagId LIMIT ?",
                arguments: StatementArguments(items.map { $0.id.uuidString }) + [OrganizeLimits.maxTagsPerItem])
            for tagId in tagIds {
                try db.execute(sql: "INSERT INTO itemTag (itemId, tagId) VALUES (?, ?)", arguments: [key, tagId])
            }
            try SearchIndex.refresh(db, itemId: key)
            return (bundleId, try Self.deleteRows(db, ids: items.map(\.id), guard: nil))
        }
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let done):
            publishOrganizeChange()
            _ = await finishDeletion(done.removed)
            return .success(done.created)
        }
    }

    private static func badGroupSelection(count: Int) -> FlotsamError {
        FlotsamError(
            .orgVal004, "Group needs 2 to the member limit of files or folders",
            context: [.count: .int(count)])
    }
}
