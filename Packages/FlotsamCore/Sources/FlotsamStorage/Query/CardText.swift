import FlotsamBase
import Foundation
import GRDB

extension FlotsamDatabase {
    /// The stored plain text of each listed item that has some, cut to `characterLimit` characters in SQL (a 5 MB
    /// text item must not be read in full to show three lines). Items with no text, an empty text, or no row are left
    /// out. Failure is `STO-DB-004`, like every other read here.
    ///
    /// Meant for one screenful of cards (the Shelf lists at most 40); every id is a bound variable.
    public func plainTexts(of ids: [UUID], characterLimit: Int) async -> FlotsamResult<[UUID: String]> {
        guard !ids.isEmpty else { return .success([:]) }
        do {
            return .success(try await pool.read { db in
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, substr(plainText, 1, ?) AS text FROM item
                        WHERE id IN (\(placeholders)) AND plainText IS NOT NULL AND plainText != ''
                        """,
                    arguments: StatementArguments([characterLimit] + ids.map(\.uuidString)))
                var texts: [UUID: String] = [:]
                for row in rows {
                    let id: String = row["id"]
                    let text: String = row["text"]
                    if let uuid = UUID(uuidString: id) { texts[uuid] = text }
                }
                return texts
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }
}
