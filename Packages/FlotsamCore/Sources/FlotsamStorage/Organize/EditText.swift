import FlotsamBase
import Foundation
import GRDB

extension FlotsamDatabase {
    /// FR-004-07: replaces an item's plain text. Returns the item's new kind, or nil when it no longer exists.
    ///
    /// Rejected without changing anything: a kind that is not text-like, or text with no non-whitespace character
    /// (`ORG-VAL-003`); text over the ingest ceiling (`ORG-LIM-003`). On save the stored rich representations (RTF,
    /// HTML) are removed, the kind and `contentKey` come from `classifiers` (the capture rules, FR-001-09 and
    /// FR-001-15), and `updatedAt` moves. `createdAt`, `lastCopiedAt`, tags, note, pin, trigger and hotkey are not
    /// touched, so exemption does not change. The new key may equal another item's; both stay (FR-004-08).
    public func editText(id: UUID, to text: String, classifiers: ItemClassifiers) async -> FlotsamResult<ItemKind?> {
        let now = clock.now().epochMillis
        let result: FlotsamResult<(kind: ItemKind, blobs: [String])?> = await organizeWrite { db in
            let key = id.uuidString
            guard let kindName = try String.fetchOne(db, sql: "SELECT kind FROM item WHERE id = ?", arguments: [key]) else {
                return nil
            }
            guard let kind = ItemKind(rawValue: kindName), kind.isTextEditable else {
                throw OrganizeRejection(error: FlotsamError(.orgVal003, "Only text-like items can be edited", context: [.itemId: .id(id)]))
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OrganizeRejection(error: FlotsamError(.orgVal003, "Edited text has no visible character", context: [.itemId: .id(id)]))
            }
            guard text.utf8.count <= IngestLimits.maxTextBytes else {
                throw OrganizeRejection(error: FlotsamError(
                    .orgLim003, "Edited text is over the text ceiling", context: [.byteSize: .bytes(IngestLimits.maxTextBytes)]))
            }

            let rich = IngestLimits.richTypeIdentifiers.sorted()
            let marks = Array(repeating: "?", count: rich.count).joined(separator: ",")
            let rows = StatementArguments([key] + rich)
            let blobs = try String.fetchAll(
                db, sql: "SELECT blobName FROM representation WHERE itemId = ? AND uti IN (\(marks))", arguments: rows)
            try db.execute(sql: "DELETE FROM representation WHERE itemId = ? AND uti IN (\(marks))", arguments: rows)

            let classification = classifiers.editedText(text)
            try db.execute(
                sql: """
                    UPDATE item SET plainText = ?, kind = ?, contentKey = ?, updatedAt = ?,
                        byteSize = (SELECT COALESCE(SUM(byteSize), 0) FROM representation WHERE itemId = ?)
                    WHERE id = ?
                    """,
                arguments: [text, classification.kind.rawValue, classification.contentKey, now, key, key])
            try SearchIndex.refresh(db, itemId: key)
            return (classification.kind, blobs)
        }
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(nil):
            return .success(nil)
        case .success(let edited?):
            publishOrganizeChange()
            // After commit, like every deletion: a blob that will not go is left for reconcile, never a failed edit.
            discardBlobs(named: edited.blobs, itemId: id)
            return .success(edited.kind)
        }
    }
}
