import FlotsamBase
import Foundation
import GRDB

/// Builds `item.searchText` (FR-007-18): the normalised concatenation of every field FR-003-09 makes searchable.
///
/// It reads the fields back from the database rather than from the caller's value, so insertion, a note edit, a tag
/// rename and a member change all go through the one implementation. Callers invoke `refresh` inside the same
/// transaction that changed a source field. Fields are joined by a newline: a search token is split on whitespace,
/// so it can never match across two fields.
enum SearchIndex {
    /// FR-003-09: only the first 10,000 characters of plain text are searchable.
    static let plainTextCharacterLimit = 10_000

    static func refresh(_ db: Database, itemId: String) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT kind, substr(plainText, 1, ?) AS text, note, name, sourceName, originalPath, isSecure
                FROM item WHERE id = ?
                """,
            arguments: [plainTextCharacterLimit, itemId])
        else { return }

        var fields: [String] = []
        // A secure clip's content is never searchable (FR-003-09); the schema keeps its plainText NULL, and this
        // keeps a future code path that sets it from reaching the index.
        let isSecure: Bool = row["isSecure"]
        if !isSecure, let text: String = row["text"] { fields.append(text) }
        if let note: String = row["note"] { fields.append(note) }
        if let name: String = row["name"] { fields.append(name) }
        fields += try String.fetchAll(
            db,
            sql: "SELECT tag.name FROM itemTag JOIN tag ON tag.id = itemTag.tagId WHERE itemTag.itemId = ? ORDER BY tag.name",
            arguments: [itemId])
        if let source: String = row["sourceName"] { fields.append(source) }
        fields += try String.fetchAll(
            db, sql: "SELECT path FROM bundleMember WHERE itemId = ? ORDER BY ordinal", arguments: [itemId]
        ).map { URL(fileURLWithPath: $0).lastPathComponent }
        if let kindName: String = row["kind"], let kind = ItemKind(rawValue: kindName) {
            fields.append(KindLabel.text(for: kind))
        }
        if let original: String = row["originalPath"] {
            fields.append(URL(fileURLWithPath: original).lastPathComponent)
        }

        try db.execute(
            sql: "UPDATE item SET searchText = ? WHERE id = ?",
            arguments: [SearchNormalizer.normalize(fields.joined(separator: "\n")), itemId])
    }
}
