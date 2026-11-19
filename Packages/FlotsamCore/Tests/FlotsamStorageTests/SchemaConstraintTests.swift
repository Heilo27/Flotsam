import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T: the FR-007-03 schema as the database enforces it. Every check reads through a separate read-only
// connection or provokes the constraint with raw SQL, so it fails when the schema changes, not when Swift code does.
// Expected values are literals.

@Suite("FRD-007 schema constraints")
struct SchemaConstraintTests {
    private func columns(_ table: String, _ store: Store) async throws -> [String] {
        try await store.reader().read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
        }
    }

    /// A minimal valid item row; the columns a test cares about are passed, the rest take the schema defaults.
    private func addItem(
        _ store: Store, _ n: Int, contentKey: String? = nil, trigger: String? = nil, hotkeyCode: Int? = nil,
        hotkeyModifiers: Int? = nil
    ) async throws {
        try await store.database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, updatedAt, "trigger", hotkeyCode, hotkeyModifiers)
                    VALUES (?, 'text', 1, 1, ?, 1, ?, ?, ?)
                    """,
                arguments: [Store.id(n).uuidString, contentKey ?? "key-\(n)", trigger, hotkeyCode, hotkeyModifiers])
        }
    }

    // OC-7012: a mutation that renames, drops or adds a column (e.g. a stored `exempt` flag) turns this red.
    @Test("OC-7012 fresh database has exactly the FR-007-03 tables and columns, and no stored exempt flag")
    func freshSchemaShape() async throws {
        // given a brand-new data folder
        let store = try await Store.make()
        defer { store.cleanUp() }

        // when the schema is introspected through a separate connection
        let tables = try await store.reader().read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        }

        // then exactly the six tables exist, each with exactly its documented columns
        #expect(tables == ["bundleMember", "item", "itemTag", "meta", "representation", "tag"])
        #expect(Set(try await columns("item", store)) == [
            "id", "kind", "createdAt", "lastCopiedAt", "copyCount", "pasteCount", "lastUsedAt", "contentKey", "plainText",
            "searchText", "sourceBundleId", "sourceName", "byteSize", "pixelWidth", "pixelHeight", "originalPath", "pinned",
            "note", "updatedAt", "hotkeyCode", "hotkeyModifiers", "trigger", "exemptReleasedAt",
            "isSecure", "secureCiphertext",
        ])
        #expect(try await columns("item", store).count == 25)
        #expect(!(try await columns("item", store)).contains("exempt"))
        #expect(Set(try await columns("representation", store)) == ["id", "itemId", "uti", "byteSize", "blobName"])
        #expect(Set(try await columns("bundleMember", store)) == ["itemId", "ordinal", "path", "bookmark", "isDirectory"])
        #expect(Set(try await columns("tag", store)) == ["id", "name", "color", "createdAt"])
        #expect(Set(try await columns("itemTag", store)) == ["itemId", "tagId"])
        #expect(Set(try await columns("meta", store)) == ["key", "value"])
    }

    // OC-7013: dropping the unique index, or its NOCASE collation, turns this red.
    @Test("OC-7013 a trigger differing only in case is rejected by the database")
    func triggerUniqueIgnoringCase() async throws {
        // given item 1 holds ';sig' and item 2 exists without a trigger
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await addItem(store, 1, trigger: ";sig")
        try await addItem(store, 2)

        // when item 2 is given ';SIG'
        // then the write is rejected as a constraint violation
        await #expect(throws: DatabaseError.self) {
            try await store.database.pool.write { db in
                try db.execute(sql: "UPDATE item SET \"trigger\" = ';SIG' WHERE id = ?", arguments: [Store.id(2).uuidString])
            }
        }

        // and only item 1 holds the trigger, item 2 still has none, both items remain
        let holders = try await store.reader().read {
            try String.fetchAll($0, sql: "SELECT id FROM item WHERE \"trigger\" = ';sig' ORDER BY id")
        }
        #expect(holders == [Store.id(1).uuidString])
        #expect(try store.trigger(of: 2) == nil)
        #expect(try store.count("item") == 2)
        // and a different trigger is still accepted (the index is not simply rejecting everything)
        try await store.database.pool.write { db in
            try db.execute(sql: "UPDATE item SET \"trigger\" = ';other' WHERE id = ?", arguments: [Store.id(2).uuidString])
        }
        #expect(try store.trigger(of: 2) == ";other")
    }

    // OC-7014: making the hotkey index non-unique, unique on code alone, or non-partial (null clash) turns this red.
    @Test("OC-7014 the same key and modifiers are rejected, a different modifier is accepted, null hotkeys coexist")
    func hotkeyUniqueness() async throws {
        // given item A holds key 40 with modifiers 256
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await addItem(store, 1, hotkeyCode: 40, hotkeyModifiers: 256)

        // when item B is given the same key and modifiers
        // then the insert is rejected and nothing was added
        await #expect(throws: DatabaseError.self) {
            try await addItem(store, 2, hotkeyCode: 40, hotkeyModifiers: 256)
        }
        #expect(try store.count("item") == 1)

        // when item C is given the same key with different modifiers
        try await addItem(store, 3, hotkeyCode: 40, hotkeyModifiers: 768)
        // and D and E have no hotkey at all
        try await addItem(store, 4)
        try await addItem(store, 5)

        // then C, D and E all exist: 4 items, 2 of them without a hotkey, 2 with
        #expect(try store.count("item") == 4)
        let nullCount = try await store.reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE hotkeyCode IS NULL")! }
        #expect(nullCount == 2)
        let held = try await store.reader().read {
            try Row.fetchAll($0, sql: "SELECT hotkeyCode, hotkeyModifiers FROM item WHERE hotkeyCode IS NOT NULL ORDER BY hotkeyModifiers")
                .map { [$0["hotkeyCode"] as Int, $0["hotkeyModifiers"] as Int] }
        }
        #expect(held == [[40, 256], [40, 768]])
    }

    // OC-7015: making contentKey unique turns this red (FRD-004 edits may create duplicates).
    @Test("OC-7015 two items with the same content key both persist")
    func contentKeyNotUnique() async throws {
        // given two inserts with an identical content key
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await addItem(store, 1, contentKey: "same-key")
        try await addItem(store, 2, contentKey: "same-key")

        // then both rows are there under their own ids
        #expect(try store.count("item") == 2)
        let ids = try await store.reader().read {
            try String.fetchAll($0, sql: "SELECT id FROM item WHERE contentKey = 'same-key' ORDER BY id")
        }
        #expect(ids == [Store.id(1).uuidString, Store.id(2).uuidString])
    }

    // OC-7016: removing ON DELETE CASCADE from any child, or cascading from itemTag to tag, turns this red.
    @Test("OC-7016 deleting the middle item removes its children but leaves tags and both neighbours intact")
    func deleteCascades() async throws {
        // given W, X, Z in that order; X (the middle) has 2 representations, 3 members, tags T1 and T2; W and Z each
        // have children and share T1 with X
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1, blobs: 1, repBytes: 10, members: [("/w", false)]))
        try await store.insert(Spec(n: 2, blobs: 2, repBytes: 10, members: [("/a", false), ("/b", false), ("/c", true)]))
        try await store.insert(Spec(n: 3, blobs: 1, repBytes: 10, members: [("/z1", false), ("/z2", false)]))
        try await store.addTags(["T1", "T2"], onItem: 2)
        try await store.database.pool.write { db in
            for n in [1, 3] {
                try db.execute(
                    sql: "INSERT INTO itemTag (itemId, tagId) SELECT ?, id FROM tag WHERE name = 'T1'",
                    arguments: [Store.id(n).uuidString])
            }
        }
        #expect(try store.presentIds() == [1, 2, 3], "precondition")
        #expect(try store.representationCount(2) == 2)
        #expect(try store.memberRows(2) == 3)
        #expect(try store.tagLinks(2) == 2)

        // when X (the middle item) is deleted
        let removed = try await store.database.delete(ids: [Store.id(2)]).get()

        // then only X is removed, its children go with it, and the full remaining set is W and Z
        #expect(removed == [Store.id(2)])
        #expect(try store.presentIds() == [1, 3])
        #expect(try store.count("item") == 2)
        #expect(try store.representationCount(2) == 0)
        #expect(try store.memberRows(2) == 0)
        #expect(try store.tagLinks(2) == 0)
        // and the tag rows are untouched
        #expect(try store.count("tag") == 2)
        // and each neighbour keeps its link to T1 only, its representations and its members
        for n in [1, 3] {
            let tags = try await store.reader().read {
                try String.fetchAll(
                    $0, sql: "SELECT tag.name FROM itemTag JOIN tag ON tag.id = itemTag.tagId WHERE itemTag.itemId = ?",
                    arguments: [Store.id(n).uuidString])
            }
            #expect(tags == ["T1"], "neighbour \(n) tag links")
            #expect(try store.representationCount(n) == 1, "neighbour \(n) representations")
        }
        #expect(try store.memberRows(1) == 1)
        #expect(try store.memberRows(3) == 2)
    }

    // OC-7019: not writing the version mirror, or not stamping the sweep, turns this red.
    @Test("OC-7019 schemaVersion mirrors user_version and one sweep stamps retention.lastSweepAt")
    func versionAndSweepStamp() async throws {
        // given a first launch at a known time and no sweep yet
        let clock = ManualClock()
        let store = try await Store.make(clock: clock)
        defer { store.cleanUp() }
        let launch = clock.millis
        let version = try await store.reader().read { try Int.fetchOne($0, sql: "PRAGMA user_version")! }
        let mirror = try await store.reader().read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'schemaVersion'") }
        let before = try await store.reader().read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'retention.lastSweepAt'") }

        // then the latest version is recorded both ways and no sweep time exists yet
        #expect(version == Migrations.all.last?.version)
        #expect(mirror == String(Migrations.all.last!.version))
        #expect(before == nil)

        // when five seconds later one sweep runs
        clock.advance(ms: 5000)
        _ = try await store.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        // then lastSweepAt is the sweep's time, which is not before launch
        let stamped = try await store.reader().read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'retention.lastSweepAt'") }
        #expect(stamped == String(launch + 5000))
        #expect(Int64(stamped ?? "0")! >= launch)
        // and the version is unchanged by the sweep
        #expect(try await store.reader().read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'schemaVersion'") } == String(Migrations.all.last!.version))
    }
}

extension Store {
    fileprivate func memberRows(_ n: Int) throws -> Int {
        try reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bundleMember WHERE itemId = ?", arguments: [Store.id(n).uuidString])! }
    }
    fileprivate func tagLinks(_ n: Int) throws -> Int {
        try reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM itemTag WHERE itemId = ?", arguments: [Store.id(n).uuidString])! }
    }
}
