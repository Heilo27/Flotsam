import FlotsamBase
import Foundation
import GRDB

extension FlotsamDatabase {
    /// FR-004-06: sets the item's one note. Only a zero-length note removes it; whitespace is stored exactly as typed
    /// (a note of spaces is a note). `nil` also removes. Longer than 2,000 characters is `ORG-VAL-002`.
    ///
    /// Characters are Unicode scalars, the unit the schema's own `CHECK (length(note) <= 2000)` counts, so the
    /// validation here and the constraint there cannot disagree and a long note can never surface as `STO-DB-001`.
    ///
    /// Returns false when the item no longer exists.
    public func setNote(_ note: String?, for id: UUID) async -> FlotsamResult<Bool> {
        let stored: String? = (note?.isEmpty ?? true) ? nil : note
        if let stored, stored.unicodeScalars.count > IngestLimits.maxNoteCharacters {
            return .failure(FlotsamError(
                .orgVal002, "Note is over the character ceiling", context: [.count: .int(IngestLimits.maxNoteCharacters)]))
        }
        let now = clock.now().epochMillis
        let result: FlotsamResult<Bool> = await organizeWrite { db in
            let key = id.uuidString
            try db.execute(sql: "UPDATE item SET note = ?, updatedAt = ? WHERE id = ?", arguments: [stored, now, key])
            guard db.changesCount > 0 else { return false }
            try SearchIndex.refresh(db, itemId: key)
            return true
        }
        if case .success(true) = result { publishOrganizeChange() }
        return result
    }
}
