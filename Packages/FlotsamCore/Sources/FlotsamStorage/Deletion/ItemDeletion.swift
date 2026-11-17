import FlotsamBase
import Foundation
import GRDB

extension FlotsamDatabase {
    /// SQLite variable ceilings differ by build; chunking inside the one transaction keeps every statement far below
    /// them while the caller still sees a single all-or-nothing delete.
    private static let deleteChunkSize = 500

    /// The only deletion path (FR-007-15): user delete, retention, budget, Clear History, ungroup, `LIB-IO-001`.
    ///
    /// Unconditional on purpose: an explicit user delete is never refused for exemption (FR-007-10), and FRD-003 owns
    /// whether a failed item is deleted, so this just deletes the ids it is given. Callers that sweep (retention,
    /// budget, Clear History) must not use it: they choose ids in a read and a pin, trigger or shortcut can land
    /// before the delete, so they use `deleteWhileEligible(ids:guard:)`, which re-applies their selection inside the
    /// delete transaction. That is the only difference between the two; the steps below are shared.
    ///
    /// Returns the ids that were actually removed: ids that did not exist (already deleted by a racing sweep) are
    /// left out so callers can report an exact count.
    public func delete(ids: [UUID]) async -> FlotsamResult<[UUID]> {
        await performDelete(ids: ids, guard: nil)
    }

    /// The sweeps' deletion: `delete(ids:)` for those of `ids` that still satisfy `guard` at the moment of deletion.
    ///
    /// The ids were chosen by a separate read, so between the read and this write the user may have pinned an item,
    /// given it a trigger or shortcut, or copied it again. The guard is the selection's own predicate (the caller
    /// builds both from one definition), evaluated inside the delete transaction: the writer is serial, so nothing
    /// can change between the check and the DELETE. An id that no longer qualifies is skipped, not deleted, and is
    /// left out of the result like an id that no longer exists.
    func deleteWhileEligible(ids: [UUID], guard deletionGuard: DeletionGuard) async -> FlotsamResult<[UUID]> {
        await performDelete(ids: ids, guard: deletionGuard)
    }

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
    private func performDelete(ids: [UUID], guard deletionGuard: DeletionGuard?) async -> FlotsamResult<[UUID]> {
        var seen = Set<String>()
        let requested = ids.map(\.uuidString).filter { seen.insert($0).inserted }
        guard !requested.isEmpty else { return .success([]) }

        let removed: [DeletedItem]
        do {
            removed = try await pool.write { db in
                var removed: [DeletedItem] = []
                for requestedChunk in requested.chunked(into: Self.deleteChunkSize) {
                    let chunk = try Self.stillDeletable(db, ids: requestedChunk, guard: deletionGuard)
                    guard !chunk.isEmpty else { continue }
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
                report(
                    FlotsamError(.stoIo003, "Blob could not be removed after delete; left for reconcile",
                                 context: [.itemId: .id(item.id)]))
            }
        }
        await discardThumbnails(itemIds: deletedIds)
        return .success(deletedIds)
    }

    /// `ids` unchanged without a guard; with one, only the ids whose row passes it right now. Runs inside the delete
    /// transaction (see `deleteWhileEligible`).
    private static func stillDeletable(_ db: Database, ids: [String], guard deletionGuard: DeletionGuard?) throws -> [String] {
        guard let deletionGuard else { return ids }
        return try String.fetchAll(
            db,
            sql: "SELECT id FROM item WHERE id IN (\(databaseQuestionMarks(count: ids.count))) AND \(deletionGuard.sql)",
            arguments: StatementArguments(ids) + deletionGuard.arguments)
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

/// A selection predicate re-applied at deletion time (see `FlotsamDatabase.deleteWhileEligible`). `sql` is a boolean
/// expression over `item`'s own columns; `arguments` are its placeholders. Built by the same code that selects, so
/// selecting and re-checking cannot disagree.
struct DeletionGuard: Sendable {
    let sql: String
    let arguments: StatementArguments
}

private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
