import FlotsamBase
import Foundation
import GRDB

extension FlotsamDatabase {
    /// SQLite variable ceilings differ by build; chunking inside the one transaction keeps every statement far below
    /// them while the caller still sees a single all-or-nothing delete.
    private static let deleteChunkSize = 500

    /// The only deletion path (FR-007-15): user delete, retention, budget, Clear History, ungroup, `LIB-IO-001`.
    ///
    /// Takes explicit ids and never a predicate, so a caller cannot widen a delete by accident; callers that sweep
    /// (retention, budget, Clear History) select their ids first and pass them in batches.
    ///
    /// Order matters and is the whole point of this function:
    /// 1. One transaction removes the item rows (representations, bundle members and tag links go by cascade) and
    ///    reads the blob names first. A failed transaction deletes nothing and returns `STO-DB-001`: no file has
    ///    been touched yet, so rows and blobs cannot disagree.
    /// 2. `itemsDeleted` is published synchronously straight after commit, so the hotkey registry and trigger
    ///    snapshot drop the items before this call returns (FR-005-22).
    /// 3. Only then are blobs and thumbnails removed. Removing a file before the commit could leave a row pointing at
    ///    nothing if the transaction then failed; removing after can at worst leave an orphan, which reconcile
    ///    deletes (FR-007-13). A blob that will not go is logged `STO-IO-003` and the delete still succeeds.
    ///
    /// Only blobs named by `representation` rows are removed. Files held by reference (`bundleMember.path`) and a
    /// screenshot's `originalPath` are never read here, so they cannot be touched.
    ///
    /// Returns the ids that were actually removed: ids that did not exist (already deleted by a racing sweep) are
    /// left out so callers can report an exact count.
    public func delete(ids: [UUID]) async -> FlotsamResult<[UUID]> {
        var seen = Set<String>()
        let requested = ids.map(\.uuidString).filter { seen.insert($0).inserted }
        guard !requested.isEmpty else { return .success([]) }

        let removed: [DeletedItem]
        do {
            removed = try await pool.write { db in
                var removed: [DeletedItem] = []
                for chunk in requested.chunked(into: Self.deleteChunkSize) {
                    let marks = databaseQuestionMarks(count: chunk.count)
                    let blobRows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT item.id AS id, representation.blobName AS blobName
                            FROM item LEFT JOIN representation ON representation.itemId = item.id
                            WHERE item.id IN (\(marks))
                            """,
                        arguments: StatementArguments(chunk))
                    guard !blobRows.isEmpty else { continue }
                    var blobsById: [String: [String]] = [:]
                    for row in blobRows {
                        let id: String = row["id"]
                        let name: String? = row["blobName"]
                        blobsById[id, default: []].append(contentsOf: name.map { [$0] } ?? [])
                    }
                    try db.execute(sql: "DELETE FROM item WHERE id IN (\(marks))", arguments: StatementArguments(chunk))
                    removed += blobsById.compactMap { id, names in
                        UUID(uuidString: id).map { DeletedItem(id: $0, blobNames: names) }
                    }
                }
                return removed
            }
        } catch {
            return .failure(Self.writeFailure(error))
        }
        guard !removed.isEmpty else { return .success([]) }

        let deletedIds = removed.map(\.id)
        events.publish(.itemsDeleted(deletedIds))
        for item in removed {
            for name in item.blobNames where !removeBlob(named: name) {
                FlotsamLog.log(
                    FlotsamError(.stoIo003, "Blob could not be removed after delete; left for reconcile",
                                 context: [.itemId: .id(item.id)]),
                    category: .storage)
            }
        }
        await discardThumbnails(itemIds: deletedIds)
        return .success(deletedIds)
    }

    /// False when the file is still there afterwards. A name that is not a plain `<shard>/<file>` path is refused
    /// rather than followed: a damaged row must never turn a delete into a removal outside `blobs/`.
    private func removeBlob(named name: String) -> Bool {
        guard BlobStore.isWellFormed(blobName: name) else { return false }
        if case .success = blobs.remove(blobName: name) { return true }
        return false
    }

    private struct DeletedItem: Sendable {
        let id: UUID
        let blobNames: [String]
    }
}

private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
