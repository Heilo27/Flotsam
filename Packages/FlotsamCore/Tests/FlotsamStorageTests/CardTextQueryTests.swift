import FlotsamBase
import Foundation
import Testing
@testable import FlotsamStorage

// FRD-006 FR-006-07: the Shelf card reads the stored plain text through one storage query, cut in SQL so a 5 MB text
// item is never read in full to show three lines.

@Suite struct CardTextQueryTests {
    private let rig: Rig

    init() async throws { rig = try await Rig.make() }

    private func insert(_ id: UUID, kind: ItemKind, text: String?) async throws {
        try await rig.store.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, updatedAt) VALUES (?, ?, 1, 1, ?, ?, 1)",
                arguments: [id.uuidString, kind.rawValue, id.uuidString, text])
        }
    }

    @Test("each listed item with text returns it; an item without text, an empty one, and an unlisted one are left out")
    func returnsTextOfListedItemsOnly() async throws {
        defer { rig.cleanUp() }
        let (a, b, none, empty, unlisted) = (UUID(), UUID(), UUID(), UUID(), UUID())
        try await insert(a, kind: .text, text: "alpha\nbeta")
        try await insert(b, kind: .link, text: "https://example.com")
        try await insert(none, kind: .image, text: nil)
        try await insert(empty, kind: .text, text: "")
        try await insert(unlisted, kind: .text, text: "not asked for")

        let texts = try await rig.store.database.plainTexts(of: [a, b, none, empty], characterLimit: 1_000).get()

        #expect(texts == [a: "alpha\nbeta", b: "https://example.com"])
    }

    @Test("text is cut to the character limit in the query")
    func cutsToTheLimit() async throws {
        defer { rig.cleanUp() }
        let id = UUID()
        try await insert(id, kind: .text, text: String(repeating: "x", count: 50))

        let texts = try await rig.store.database.plainTexts(of: [id], characterLimit: 10).get()

        #expect(texts[id] == String(repeating: "x", count: 10))
    }

    @Test("no ids is an empty result, not a query")
    func noIds() async throws {
        defer { rig.cleanUp() }
        #expect(try await rig.store.database.plainTexts(of: [], characterLimit: 10).get().isEmpty)
    }
}
