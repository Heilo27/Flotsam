import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf
@testable import FlotsamStorage

// FRD-006 FR-006-07: the real adapter. A text card shows the first four lines of the stored text read through
// `FlotsamDatabase`, where the row's own primary line holds only two.

private final class NullSink: LogSink, @unchecked Sendable {
    func write(_ record: LogRecord) {}
}

@MainActor @Suite struct ShelfCardDetailsTests {
    @Test("OC-S2-D1 a text card on the real database shows four lines of the stored text, not the two of the primary line")
    func cardShowsThreeStoredLines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-details-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await FlotsamDatabase.open(folder: root, logSink: NullSink()).get()
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, updatedAt) VALUES (?, 'text', 1, 1, 'key', ?, 1)",
                arguments: [id.uuidString, "one\ntwo\nthree\nfour\nfive"])
        }
        let model = ShelfModel(source: database, paster: FakeShelfPaster(), host: FakeShelfHost(), events: ItemEventBus(), details: database)

        await model.open(target: textEdit, sticky: true)

        #expect(model.sections().flatMap(\.cards).first { $0.id == id }?.text == "one\ntwo\nthree\nfour")
    }
}
