import FlotsamBase
import Foundation
import GRDB

/// Builds the two search columns of an item (FR-007-18, FR-010-08), from one field list so they cannot drift:
/// - `item.searchText`: the normalised concatenation of every field FR-003-09 makes searchable. The Library and the Shelf
///   match against it.
/// - `item.searchTextExposed`: the same, minus every field an outside reader (an approved MCP client, FRD-010) is not
///   shown. It never holds recognised image text (FR-003-55: for in-app search only), the bundle name, the kind label or
///   the original file name, and holds at most the first `ExposureLimits.maxFileNames` member names, which is all that
///   `get_item` returns. A match is an answer to "does this text occur", so any matched field is readable by probing;
///   the only safe surface is the one the tool already returns.
///
/// It reads the fields back from the database rather than from the caller's value, so insertion, a note edit, a tag
/// rename and a member change all go through the one implementation. Callers invoke `refresh` inside the same
/// transaction that changed a source field. Fields are joined by a newline: a search token is split on whitespace,
/// so it can never match across two fields.
enum SearchIndex {
    /// FR-003-09: only the first 10,000 characters of plain text are searchable.
    static let plainTextCharacterLimit = 10_000
    /// FR-007-23: recognised image text is bounded the same way. The `item.ocrText` CHECK in migration 4 spells the same number.
    static let recognizedTextCharacterLimit = 10_000

    static func refresh(_ db: Database, itemId: String) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT kind, substr(plainText, 1, ?) AS text, substr(ocrText, 1, ?) AS recognized, note, name, sourceName, originalPath, isSecure
                FROM item WHERE id = ?
                """,
            arguments: [plainTextCharacterLimit, recognizedTextCharacterLimit, itemId])
        else { return }

        // Every field goes to `library`; only the ones an MCP client is shown also go to `exposed`.
        var library: [String] = []
        var exposed: [String] = []
        func add(_ field: String, exposedToo: Bool) {
            library.append(field)
            if exposedToo { exposed.append(field) }
        }

        // A secure clip's content is never searchable (FR-003-09); the schema keeps its plainText NULL, and this
        // keeps a future code path that sets it from reaching the index.
        let isSecure: Bool = row["isSecure"]
        if !isSecure, let text: String = row["text"] { add(text, exposedToo: true) }
        // FR-003-55: what text recognition read from an image is searchable, and only searchable: nothing else reads it,
        // and an MCP client never matches against it (FRD-010 FR-010-08).
        if !isSecure, let recognized: String = row["recognized"] { add(recognized, exposedToo: false) }
        if let note: String = row["note"] { add(note, exposedToo: true) }
        if let name: String = row["name"] { add(name, exposedToo: false) }
        for tag in try String.fetchAll(
            db,
            sql: "SELECT tag.name FROM itemTag JOIN tag ON tag.id = itemTag.tagId WHERE itemTag.itemId = ? ORDER BY tag.name",
            arguments: [itemId])
        { add(tag, exposedToo: true) }
        if let source: String = row["sourceName"] { add(source, exposedToo: true) }
        let members = try String.fetchAll(
            db, sql: "SELECT path FROM bundleMember WHERE itemId = ? ORDER BY ordinal", arguments: [itemId]
        ).map { URL(fileURLWithPath: $0).lastPathComponent }
        for (index, member) in members.enumerated() { add(member, exposedToo: index < ExposureLimits.maxFileNames) }
        if let kindName: String = row["kind"], let kind = ItemKind(rawValue: kindName) {
            add(KindLabel.text(for: kind), exposedToo: false)
        }
        if let original: String = row["originalPath"] {
            add(URL(fileURLWithPath: original).lastPathComponent, exposedToo: false)
        }

        try db.execute(
            sql: "UPDATE item SET searchText = ?, searchTextExposed = ? WHERE id = ?",
            arguments: [
                SearchNormalizer.normalize(library.joined(separator: "\n")),
                SearchNormalizer.normalize(exposed.joined(separator: "\n")), itemId,
            ])
    }
}
