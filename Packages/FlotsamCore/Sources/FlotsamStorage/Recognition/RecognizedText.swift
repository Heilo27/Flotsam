import FlotsamBase
import Foundation
import GRDB

/// The queue and the store behind image-text search (FRD-007 FR-007-23). `TextRecognitionIndexer` drives them.
extension FlotsamDatabase {
    /// An image or screenshot still waiting for recognition: its id and the blob that holds its pixels.
    struct RecognitionCandidate: Sendable, Equatable {
        let itemId: UUID
        /// The primary representation (lowest id, FR-007-04); nil when the row has none, which is recorded as a failed read.
        let blobName: String?
    }

    /// The kinds recognition applies to, as SQL literals. Spelt as in migration 4's `item_ocrPending` index.
    private static var recognizableKindsSQL: String {
        [ItemKind.image, .screenshot].map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }

    /// The newest `limit` items that have never been through recognition. Secure items are never listed (FR-007-23);
    /// the predicate is the partial index's own, so this is an index range read and costs nothing once the backfill is done.
    func itemsAwaitingRecognition(limit: Int) async -> FlotsamResult<[RecognitionCandidate]> {
        do {
            return .success(try await pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT item.id AS id,
                               (SELECT blobName FROM representation WHERE itemId = item.id ORDER BY id LIMIT 1) AS blobName
                        FROM item
                        WHERE ocrAt IS NULL AND isSecure = 0 AND kind IN (\(Self.recognizableKindsSQL))
                        ORDER BY lastCopiedAt DESC
                        LIMIT ?
                        """,
                    arguments: [limit]
                ).compactMap { row -> RecognitionCandidate? in
                    let id: String = row["id"]
                    guard let itemId = UUID(uuidString: id) else { return nil }
                    return RecognitionCandidate(itemId: itemId, blobName: row["blobName"])
                }
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }

    /// Records that recognition finished for `itemId` and indexes what it read. `text` nil, empty or blank means the
    /// image holds no text (or could not be read): the attempt is still recorded so the item is not queued again.
    ///
    /// One transaction writes the text and rebuilds `searchText`, so search never sees one without the other. It does
    /// nothing when the item is gone (deleted while it was being read), is secure, or was already recorded. It does
    /// not touch `updatedAt` or `lastCopiedAt`, so recognition never reorders the Library, and it publishes no event:
    /// the next query sees the text, and a refresh per image would redraw the panel for nothing.
    func storeRecognizedText(_ text: String?, itemId: UUID) async -> FlotsamResult<Void> {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Unicode scalars, not Characters: the CHECK in migration 4 counts code points.
        let bounded = trimmed.isEmpty ? nil : String(trimmed.unicodeScalars.prefix(SearchIndex.recognizedTextCharacterLimit))
        let now = clock.now().epochMillis
        do {
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE item SET ocrText = ?, ocrAt = ? WHERE id = ? AND ocrAt IS NULL AND isSecure = 0",
                    arguments: [bounded, now, itemId.uuidString])
                if db.changesCount > 0 { try SearchIndex.refresh(db, itemId: itemId.uuidString) }
            }
            return .success(())
        } catch {
            return .failure(Self.writeFailure(error))
        }
    }

    /// The bytes of the image to read, or a `STO-IO-001` failure when the blob name is damaged or the file is gone.
    func recognitionSource(_ candidate: RecognitionCandidate) -> FlotsamResult<Data> {
        let failure = FlotsamError(.stoIo001, "Image to recognise could not be read", context: [.itemId: .id(candidate.itemId)])
        guard let name = candidate.blobName, BlobStore.isWellFormed(blobName: name),
              case .success(let data) = blobs.read(blobName: name)
        else { return .failure(failure) }
        return .success(data)
    }
}
