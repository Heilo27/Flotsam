import FlotsamBase
import Foundation
import GRDB

/// What one reconcile pass repaired (FR-007-13).
public struct ReconcileOutcome: Sendable, Equatable {
    public let orphanBlobsRemoved: Int
    public let missingBlobRowsRemoved: Int
    /// Items removed because losing their last representation left nothing to show or paste.
    public let itemsRemoved: Int
    public let orphanThumbnailsRemoved: Int

    public var isClean: Bool {
        orphanBlobsRemoved + missingBlobRowsRemoved + itemsRemoved + orphanThumbnailsRemoved == 0
    }
}

extension FlotsamDatabase {
    /// A blob younger than this may be mid-ingest: `BlobStore` renames the file into place and only then commits the
    /// row that references it, so a brand-new unreferenced file is normal, not an orphan (FR-007-13).
    private static let orphanGraceMillis: Int64 = 10 * 60 * 1000

    /// Kinds whose content is a list of file references (`bundleMember` rows), not blobs or text, so having no
    /// representation and no plain text is their normal shape.
    private static let referenceKinds = ItemKind.allCases.filter(\.referencesFiles).map(\.rawValue)

    /// Brings the database and the folder back into agreement after a crash or an outside deletion (FR-007-13).
    /// Run at launch and weekly by `ReconcileScheduler`; safe to run while ingest, delete and retention are working.
    ///
    /// Why the order is fixed: the representation rows are read first and the `blobs/` listing second. A blob that
    /// ingest finishes in between is younger than the grace and so is never judged an orphan, and a row committed
    /// after the read is simply not looked at. Reading the listing first would let such a row look like a missing
    /// blob and be wrongly removed.
    ///
    /// Repairs, each logged `STO-IO-003` with ids and counts only (never names or paths, TRUTHS A4):
    /// - An unreferenced blob older than 10 minutes is deleted. Only files named like `BlobStore` names them.
    /// - A representation row whose blob is gone is removed. If its item is then left with no plain text, no
    ///   representation and is not a file-reference kind, the item goes too, through `delete(ids:)` so hotkeys,
    ///   triggers and thumbnails are cleaned up the same way as any other deletion.
    /// - A thumbnail whose item no longer exists is deleted silently: it is regenerable and not a fault.
    ///
    /// Safety valve: if any part of `blobs/` could not be listed or read (a folder, or a listed file that would not
    /// stat), the missing-blob pass is skipped. "Not listed" is not "not there", and treating an unreadable folder
    /// as proof that every blob is missing would wipe the library.
    public func reconcile() async -> FlotsamResult<ReconcileOutcome> {
        let referenced: [ReferencedBlob]
        do {
            referenced = try await pool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, itemId, blobName FROM representation").map {
                    ReferencedBlob(representationId: $0["id"], itemId: $0["itemId"], blobName: $0["blobName"])
                }
            }
        } catch {
            return .failure(Self.readFailure(error))
        }

        let listing = listBlobs()
        let referencedNames = Set(referenced.map(\.blobName))
        let orphanBlobsRemoved = removeOrphanBlobs(listing: listing, referencedNames: referencedNames)
        await Task.yield()

        var missingRows = 0
        var itemsRemoved = 0
        if listing.complete {
            let present = Set(listing.files.map(\.name))
            let missing = referenced.filter { !present.contains($0.blobName) }
            switch await removeMissingBlobRows(missing) {
            case .success(let result): (missingRows, itemsRemoved) = result
            case .failure(let error): return .failure(error)
            }
        }
        await Task.yield()

        let thumbnails = await removeOrphanThumbnails()
        return .success(
            ReconcileOutcome(
                orphanBlobsRemoved: orphanBlobsRemoved, missingBlobRowsRemoved: missingRows,
                itemsRemoved: itemsRemoved, orphanThumbnailsRemoved: thumbnails))
    }

    private struct ReferencedBlob: Sendable {
        let representationId: Int64
        let itemId: String
        let blobName: String
    }

    private struct ListedBlob {
        let name: String
        /// Nil when the file was listed but could not be stat'ed. Its age is then unknown, so it is never an orphan.
        let modifiedAt: Date?
    }

    private struct BlobListing {
        var files: [ListedBlob] = []
        /// False when any shard folder or any listed file could not be read, so absence from `files` proves nothing.
        var complete = true
    }

    /// Every `<shard>/<file>` under `blobs/`. Shard folders are the two-character directories `BlobStore` creates;
    /// anything else at the top level is not ours and is ignored rather than counted as a failure.
    private func listBlobs() -> BlobListing {
        var listing = BlobListing()
        guard case .success(let shards) = fileSystem.contentsOfDirectory(at: folder.blobsURL) else {
            listing.complete = false
            return listing
        }
        for shard in shards where shard.lastPathComponent.count == 2 {
            guard case .success(let entries) = fileSystem.contentsOfDirectory(at: shard) else {
                listing.complete = false
                continue
            }
            for entry in entries {
                let file = entry.lastPathComponent
                guard BlobStore.isGeneratedFileName(file) else { continue }
                // A file the directory listing returned exists. A failed stat is a transient fault, not absence: keep
                // it in `files` (so it counts as present) and mark the listing incomplete, so the missing-blob repair
                // does not run on evidence we know is partial. Only the size and age checks may skip it.
                let info = fileSystem.fileInfo(at: entry)
                if info == nil { listing.complete = false }
                listing.files.append(
                    ListedBlob(name: "\(shard.lastPathComponent)/\(file)", modifiedAt: info?.modifiedAt))
            }
        }
        return listing
    }

    private func removeOrphanBlobs(listing: BlobListing, referencedNames: Set<String>) -> Int {
        let cutoff = clock.now().epochMillis - Self.orphanGraceMillis
        var removed = 0
        for blob in listing.files
        where !referencedNames.contains(blob.name) && (blob.modifiedAt.map { $0.epochMillis < cutoff } ?? false) {
            guard case .success = blobs.remove(blobName: blob.name) else { continue }
            removed += 1
            report(FlotsamError(.stoIo003, "Orphan blob removed by reconcile"))
        }
        return removed
    }

    /// Removes the rows in one transaction and finds which items that left empty, then deletes those items. Rows
    /// already gone (a racing delete cascaded them) change nothing and are not counted or logged.
    private func removeMissingBlobRows(_ missing: [ReferencedBlob]) async -> FlotsamResult<(rows: Int, items: Int)> {
        guard !missing.isEmpty else { return .success((0, 0)) }
        let emptied: (rows: [ReferencedBlob], itemIds: [UUID])
        do {
            emptied = try await pool.write { db in
                var removedRows: [ReferencedBlob] = []
                var touched = Set<String>()
                for row in missing {
                    try db.execute(sql: "DELETE FROM representation WHERE id = ?", arguments: [row.representationId])
                    guard db.changesCount == 1 else { continue }
                    removedRows.append(row)
                    touched.insert(row.itemId)
                }
                var empty: [UUID] = []
                for chunk in Array(touched).chunked(into: 500) {
                    let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    let kinds = Array(repeating: "?", count: Self.referenceKinds.count).joined(separator: ",")
                    let ids = try String.fetchAll(
                        db,
                        sql: """
                            SELECT id FROM item
                            WHERE id IN (\(marks))
                              AND (plainText IS NULL OR plainText = '')
                              AND isSecure = 0
                              AND kind NOT IN (\(kinds))
                              AND NOT EXISTS (SELECT 1 FROM representation WHERE representation.itemId = item.id)
                            """,
                        arguments: StatementArguments(chunk + Self.referenceKinds))
                    empty += ids.compactMap { UUID(uuidString: $0) }
                }
                return (removedRows, empty)
            }
        } catch {
            return .failure(Self.writeFailure(error))
        }
        for row in emptied.rows {
            var context: [LogKey: LogSafeValue] = [:]
            if let id = UUID(uuidString: row.itemId) { context[.itemId] = .id(id) }
            report(
                FlotsamError(.stoIo003, "Representation row with a missing blob removed by reconcile", context: context))
        }
        switch await delete(ids: emptied.itemIds) {
        case .success(let removedItems): return .success((emptied.rows.count, removedItems.count))
        case .failure(let error): return .failure(error)
        }
    }

    /// Deletes `thumbs/<uuid>-<edge>.jpg` files whose item is gone. The thumbnail listing is taken before the item
    /// ids are read, so a thumbnail made for an item inserted in between is still matched. Names that do not parse
    /// are left alone. Silent by spec: no log, no error.
    private func removeOrphanThumbnails() async -> Int {
        guard case .success(let files) = fileSystem.contentsOfDirectory(at: folder.thumbsURL) else { return 0 }
        let candidates: [(url: URL, itemId: UUID)] = files.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".jpg"), name.count > 36, let id = UUID(uuidString: String(name.prefix(36))) else {
                return nil
            }
            return (url, id)
        }
        guard !candidates.isEmpty else { return 0 }
        let existing: Set<String>
        do {
            existing = try await pool.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM item")) }
        } catch {
            return 0
        }
        var removed = 0
        for candidate in candidates where !existing.contains(candidate.itemId.uuidString) {
            if case .success = fileSystem.removeItem(at: candidate.url) { removed += 1 }
            await thumbnails.evict(itemId: candidate.itemId)
        }
        return removed
    }
}
