import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-260 / FR-004-14: pin, note, edit and delete are each one transaction. The fault is injected with the same seam the
// tag, ungroup and ingest tests use (a SQLite trigger that raises ABORT partway through the transaction), placed AFTER
// earlier statements of the same transaction already ran, so a missing transaction leaves visible partial state. Every
// expected value is a literal; state is read back through a second read-only connection (Store.reader), never the writer.
// Each test also removes the trigger and repeats the action to prove the trigger, not the input, was the cause.

private let classifiers = ItemClassifiers(
    editedText: { ItemClassification(kind: .text, contentKey: "edit:" + $0) },
    fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) })

private func code<T>(_ result: FlotsamResult<T>) -> ErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

private extension Store {
    func install(_ trigger: String) async throws {
        try await database.pool.write { try $0.execute(sql: trigger) }
    }

    func dropTrigger() async throws {
        try await database.pool.write { try $0.execute(sql: "DROP TRIGGER inject_failure") }
    }

    /// Every row of `table`, whole, in a stable order: a before/after comparison catches any column that moved.
    func dump(_ table: String, orderBy: String = "rowid") throws -> [String] {
        try reader().read { db in try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(orderBy)").map { "\($0)" } }
    }

    func scalar(_ sql: String) throws -> Int {
        try reader().read { try Int.fetchOne($0, sql: sql) ?? -1 }
    }

    func text(_ sql: String) throws -> [String?] {
        try reader().read { try String?.fetchAll($0, sql: sql) }
    }
}

@Suite struct OrganizeTransactionalityFaultTests {

    // OC-4101 family. Red if pin writes per item outside one transaction (items 1 and 2 would stay pinned).
    @Test("OC-4101 given 5 unpinned items and a failure on the 3rd pin write, when pinned, then STO-DB-001, count delta 0, nobody is pinned")
    func pinFailureLeavesNothing() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...5).map { Spec(n: $0, ageMs: Int64($0) * 1000) })
        let itemsBefore = try store.dump("item")
        try await store.install("""
            CREATE TRIGGER inject_failure BEFORE UPDATE OF pinned ON item WHEN NEW.id = '\(Store.id(3).uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        let events = EventCollector(store.database.events)

        let result = await store.database.togglePinned(ids: (1...5).map(Store.id))

        #expect(code(result) == .stoDb001)
        #expect(try store.count("item") == 5)
        #expect(try store.scalar("SELECT COUNT(*) FROM item WHERE pinned = 1") == 0)
        #expect(try store.dump("item") == itemsBefore)
        #expect(events.events.isEmpty)

        // control: with the fault gone the same call pins all five
        try await store.dropTrigger()
        #expect(try await store.database.togglePinned(ids: (1...5).map(Store.id)).get() == true)
        #expect(try store.scalar("SELECT COUNT(*) FROM item WHERE pinned = 1") == 5)
        #expect(try store.count("item") == 5)
    }

    // Red if a failed unpin of pinned items stamps exemptReleasedAt/updatedAt on the ones processed before the failure.
    @Test("OC-4101 given 3 pinned items and a failure on the 3rd unpin, when unpinned, then all 3 stay pinned and no release stamp is written")
    func unpinFailureKeepsPinsAndStamps() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...3).map { Spec(n: $0, ageMs: Int64($0) * 1000, pinned: true) })
        let itemsBefore = try store.dump("item")
        try await store.install("""
            CREATE TRIGGER inject_failure BEFORE UPDATE OF pinned ON item WHEN NEW.id = '\(Store.id(3).uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)

        let result = await store.database.setPinned(ids: (1...3).map(Store.id), pinned: false)

        #expect(code(result) == .stoDb001)
        #expect(try store.count("item") == 3)
        #expect(try store.scalar("SELECT COUNT(*) FROM item WHERE pinned = 1") == 3)
        #expect(try store.scalar("SELECT COUNT(*) FROM item WHERE exemptReleasedAt IS NOT NULL") == 0)
        #expect(try store.dump("item") == itemsBefore)
    }

    // Red if setNote writes the note and the search index refresh sits outside the transaction (the note would stay).
    @Test("OC-4101 given an item and a failure while its search text is refreshed, when a note is set, then STO-DB-001 and no note, old search text")
    func noteFailureLeavesNothing() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 1000), Spec(n: 2, ageMs: 2000)])
        _ = try await store.database.setNote("keep me", for: Store.id(2)).get()
        let before = try store.dump("item")
        try await store.install("""
            CREATE TRIGGER inject_failure BEFORE UPDATE OF searchText ON item WHEN NEW.id = '\(Store.id(1).uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        let events = EventCollector(store.database.events)

        let result = await store.database.setNote("brand new note", for: Store.id(1))

        #expect(code(result) == .stoDb001)
        #expect(try store.count("item") == 2)
        #expect(try store.text("SELECT note FROM item ORDER BY id") == [nil, "keep me"])
        #expect(try store.dump("item") == before)
        #expect(try await store.database.matches("brand").unique.isEmpty)
        #expect(events.events.isEmpty)

        // control
        try await store.dropTrigger()
        #expect(try await store.database.setNote("brand new note", for: Store.id(1)).get() == true)
        #expect(try store.text("SELECT note FROM item ORDER BY id") == ["brand new note", "keep me"])
        #expect(try await store.database.matches("brand").unique == [Store.id(1)])
    }

    // Red if editText deletes the rich representations (or updates the text) outside the transaction that fails last.
    @Test("OC-4101 given a text item with a stored RTF and a failure on the final step, when edited, then STO-DB-001 and text, kind, key, RTF row and blob are untouched")
    func editFailureLeavesNothing() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 1000, blobs: 1, repBytes: 10, text: "original"), Spec(n: 2, ageMs: 2000)])
        let itemsBefore = try store.dump("item")
        let repsBefore = try store.dump("representation")
        #expect(try store.representationCount(1) == 1)
        try await store.install("""
            CREATE TRIGGER inject_failure BEFORE UPDATE OF searchText ON item WHEN NEW.id = '\(Store.id(1).uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        let events = EventCollector(store.database.events)

        let result = await store.database.editText(id: Store.id(1), to: "replacement", classifiers: classifiers)

        #expect(code(result) == .stoDb001)
        #expect(try store.count("item") == 2)
        #expect(try store.text("SELECT plainText FROM item ORDER BY id") == ["original", "item 2"])
        #expect(try store.text("SELECT contentKey FROM item ORDER BY id") == ["key-1", "key-2"])
        #expect(try store.dump("item") == itemsBefore)
        #expect(try store.representationCount(1) == 1)
        #expect(try store.dump("representation") == repsBefore)
        #expect(store.exists(store.blobURL(1, 1)))
        #expect(store.contents(store.blobURL(1, 1)) == "blob-1-1")
        #expect(events.events.isEmpty)

        // control
        try await store.dropTrigger()
        #expect(try await store.database.editText(id: Store.id(1), to: "replacement", classifiers: classifiers).get() == .text)
        #expect(try store.text("SELECT plainText FROM item ORDER BY id") == ["replacement", "item 2"])
        #expect(try store.representationCount(1) == 0)
        #expect(try store.count("item") == 2)
    }

    // Red if delete removes rows per item/chunk outside one transaction, or removes blobs/thumbnails before the commit.
    @Test("OC-4101 given 5 items with blobs, tags and a failure on the 4th row delete, when deleted, then STO-DB-001, all 5 rows, links, blobs, thumbs stay and nothing is announced")
    func deleteFailureLeavesNothing() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...5).map { Spec(n: $0, ageMs: Int64($0) * 1000, blobs: 1, repBytes: 10, thumbs: true) })
        try await store.addTags(["keep"], onItem: 1)
        try await store.addTags(["keep too"], onItem: 5)
        let itemsBefore = try store.dump("item")
        try await store.install("""
            CREATE TRIGGER inject_failure BEFORE DELETE ON item WHEN OLD.id = '\(Store.id(4).uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        let events = EventCollector(store.database.events)

        let result = await store.database.delete(ids: (1...5).map(Store.id))

        #expect(code(result) == .stoDb001)
        #expect(try store.count("item") == 5)
        #expect(try store.presentIds() == [1, 2, 3, 4, 5])
        #expect(try store.count("representation") == 5)
        #expect(try store.count("itemTag") == 2)
        #expect(try store.dump("item") == itemsBefore)
        for n in 1...5 {
            #expect(store.exists(store.blobURL(n, 1)), "blob \(n) must stay")
            #expect(store.exists(store.thumbURL(n, 256)), "thumbnail \(n) must stay")
        }
        #expect(events.events.isEmpty)

        // control: with the fault gone exactly the requested ids go
        try await store.dropTrigger()
        let removed = try await store.database.delete(ids: [Store.id(1), Store.id(4)]).get()
        #expect(Set(removed) == [Store.id(1), Store.id(4)])
        #expect(try store.presentIds() == [2, 3, 5])
        #expect(try store.count("item") == 3)
        #expect(!store.exists(store.blobURL(1, 1)))
        #expect(store.exists(store.blobURL(2, 1)))
    }

    // Boundary max+1: deletion runs in chunks of 500 rows (ItemDeletion.deleteChunkSize, private). A failure in the 2nd chunk
    // must undo the 1st: with 501 items, one statement per chunk, only the surrounding transaction can do that.
    // Red if performDelete stops wrapping the chunks in one transaction (the first 500 rows would be gone).
    @Test("OC-4101 given 501 items (one more than a delete chunk) and a failure on the last row, when all are deleted, then STO-DB-001 and all 501 rows remain")
    func deleteFailureInSecondChunkRollsBackFirst() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...501).map { Spec(n: $0, ageMs: Int64($0)) })
        try await store.install("""
            CREATE TRIGGER inject_failure BEFORE DELETE ON item WHEN OLD.id = '\(Store.id(501).uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        let events = EventCollector(store.database.events)

        let result = await store.database.delete(ids: (1...501).map(Store.id))

        #expect(code(result) == .stoDb001)
        #expect(try store.count("item") == 501)
        #expect(try store.scalar("SELECT COUNT(*) FROM item WHERE id = '\(Store.id(1).uuidString)'") == 1)
        #expect(try store.scalar("SELECT COUNT(*) FROM item WHERE id = '\(Store.id(500).uuidString)'") == 1)
        #expect(events.events.isEmpty)

        // control: without the fault all 501 go
        try await store.dropTrigger()
        #expect(try await store.database.delete(ids: (1...501).map(Store.id)).get().count == 501)
        #expect(try store.count("item") == 0)
    }

    // Boundary: a failing delete of an id that does not exist is a no-op success, not a fault (trigger never fires).
    @Test("OC-4101 given the trigger armed on a missing id, when only existing ids are deleted, then the trigger stays silent and they go")
    func faultOnOtherRowDoesNotBlockDelete() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...3).map { Spec(n: $0) })
        try await store.install("""
            CREATE TRIGGER inject_failure BEFORE DELETE ON item WHEN OLD.id = '\(Store.id(3).uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)

        let removed = try await store.database.delete(ids: [Store.id(1), Store.id(2)]).get()

        #expect(Set(removed) == [Store.id(1), Store.id(2)])
        #expect(try store.presentIds() == [3])
    }
}
