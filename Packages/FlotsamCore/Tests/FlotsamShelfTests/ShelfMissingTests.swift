import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf
@testable import FlotsamStorage

// FRD-006 FR-006-07 / FRD-003 FR-003-07 (AC-003-05a): the Shelf badge and the Library list and grid share one Missing
// state. An item is Missing when none of its members exist (a moved member whose bookmark resolves exists; an empty
// bundle is Missing). Real files, real bookmarks, real LocalFileSystem. Both surfaces read a real database: the Shelf
// shows `ItemRow.isMissing` from the same query the Library uses (S1 ruling 2026-11-17), it has no Missing rule of its
// own to test beyond that.

private final class NullSink: LogSink, @unchecked Sendable {
    func write(_ record: LogRecord) {}
}

@MainActor @Suite struct ShelfMissingTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: Fixtures

    /// A real file and a member that remembers it by path and by bookmark.
    private func member(_ name: String) throws -> (url: URL, member: ItemMember) {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return (url, ItemMember(path: url.path, bookmark: try url.bookmarkData(), isDirectory: false))
    }

    private func relocate(_ url: URL, to name: String) throws {
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent(name))
    }

    /// A real database holding one item of `kind` with `members`.
    private func database(kind: ItemKind, members: [ItemMember]) async throws -> (database: FlotsamDatabase, id: UUID) {
        let root = dir.appendingPathComponent("library-\(UUID().uuidString)")
        let database = try await FlotsamDatabase.open(folder: root, logSink: NullSink()).get()
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, updatedAt) VALUES (?, ?, 1, 1, 'key', 1)",
                arguments: [id.uuidString, kind.rawValue])
            for (ordinal, member) in members.enumerated() {
                try db.execute(
                    sql: "INSERT INTO bundleMember (itemId, ordinal, path, bookmark, isDirectory) VALUES (?, ?, ?, ?, ?)",
                    arguments: [id.uuidString, ordinal, member.path, member.bookmark, member.isDirectory ? 1 : 0])
            }
        }
        return (database, id)
    }

    /// The card the real Shelf model draws for the item.
    private func shelfMissing(kind: ItemKind, members: [ItemMember]) async throws -> Bool {
        let (database, id) = try await database(kind: kind, members: members)
        let model = ShelfModel(source: database, paster: FakeShelfPaster(), host: FakeShelfHost(), events: ItemEventBus(), details: database)
        await model.open(target: textEdit, sticky: true)
        return try #require(model.sections().flatMap(\.cards).first { $0.id == id }, "the item is not on the Shelf").isMissing
    }

    private func libraryMissing(kind: ItemKind, members: [ItemMember]) async throws -> Bool {
        let (database, id) = try await database(kind: kind, members: members)
        let page = try await database.items(matching: LibraryQuery()).get()
        return try #require(page.rows.first { $0.id == id }, "the item is not on the Library page").isMissing
    }

    /// The item's state on the Shelf and in the Library, which must be the same.
    private func both(kind: ItemKind = .bundle, _ members: [ItemMember]) async throws -> (shelf: Bool, library: Bool) {
        (try await shelfMissing(kind: kind, members: members), try await libraryMissing(kind: kind, members: members))
    }

    // MARK: FR-003-07 through the Shelf

    // Red if the Shelf goes back to checking the stored path only (the moved file's old path is gone).
    @Test("OC-S2-M1 a bundle member that moved, with a bookmark that resolves, is not Missing on the Shelf")
    func movedBundleMemberIsNotMissing() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try member("a.txt")
        try relocate(a.url, to: "a-moved.txt")

        #expect(try await shelfMissing(kind: .bundle, members: [a.member]) == false)
    }

    // Red if the Shelf treats a bookmark as proof of existence, or ignores the member entirely.
    @Test("OC-S2-M2 a deleted bundle member is Missing on the Shelf")
    func deletedBundleMemberIsMissing() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try member("a.txt")
        try FileManager.default.removeItem(at: a.url)

        #expect(try await shelfMissing(kind: .bundle, members: [a.member]) == true)
    }

    // Red if the Shelf marks a non-file card, or a file card the storage query did not mark.
    @Test("OC-S2-M3 a text card is never Missing, even when stray members point at nothing")
    func nonFileCardIsNeverMissing() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let gone = ItemMember(path: dir.appendingPathComponent("nope").path, bookmark: nil, isDirectory: false)

        #expect(try await shelfMissing(kind: .text, members: [gone]) == false)
    }

    // MARK: Shelf and Library agree (Rule 9)

    // Red if either surface decides Missing by its own rule.
    @Test("OC-S2-M4 Shelf and Library agree: every member present, one moved, one deleted, all gone, empty")
    func shelfAndLibraryAgree() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let present = try member("present.txt")
        let moved = try member("moved.txt")
        try relocate(moved.url, to: "moved-away.txt")
        let deleted = try member("deleted.txt")
        try FileManager.default.removeItem(at: deleted.url)
        let alsoDeleted = try member("also-deleted.txt")
        try FileManager.default.removeItem(at: alsoDeleted.url)

        let cases: [(name: String, kind: ItemKind, members: [ItemMember], missing: Bool)] = [
            ("all present", .bundle, [present.member], false),
            ("moved, bookmark resolves", .bundle, [moved.member], false),
            ("partially gone", .bundle, [present.member, deleted.member], false),
            ("partially gone, survivor moved", .bundle, [deleted.member, moved.member], false),
            ("all gone", .bundle, [deleted.member, alsoDeleted.member], true),
            ("single file gone", .file, [deleted.member], true),
            ("empty bundle", .bundle, [], true),
        ]
        for testCase in cases {
            let state = try await both(kind: testCase.kind, testCase.members)
            #expect(state.shelf == testCase.missing, "Shelf: \(testCase.name)")
            #expect(state.library == testCase.missing, "Library: \(testCase.name)")
            #expect(state.shelf == state.library, "agreement: \(testCase.name)")
        }
    }
}
