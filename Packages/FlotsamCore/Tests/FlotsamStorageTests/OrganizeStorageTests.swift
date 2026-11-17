import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-004 unit tests for the Storage organise commands (FR-004-01..08, 11, 14). Expected values are literals. Rows are
// read back through a second connection. Kind detection and keys are injected, as in the app, so these use a small fake.

private let fakeClassifiers = ItemClassifiers(
    editedText: { text in
        ItemClassification(kind: text.hasPrefix("https://") ? .link : .text, contentKey: "edit:" + text)
    },
    fileMember: { path, isDirectory in
        ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path)
    })

private struct Snapshot: Equatable {
    var kind: String
    var plainText: String?
    var contentKey: String
    var note: String?
    var pinned: Bool
    var lastCopiedAt: Int64
    var createdAt: Int64
    var updatedAt: Int64
    var searchText: String
}

private extension Store {
    func snapshot(_ n: Int) throws -> Snapshot? { try snapshot(Store.id(n)) }

    func snapshot(_ id: UUID) throws -> Snapshot? {
        try reader().read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM item WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return Snapshot(
                kind: row["kind"], plainText: row["plainText"], contentKey: row["contentKey"], note: row["note"],
                pinned: row["pinned"], lastCopiedAt: row["lastCopiedAt"], createdAt: row["createdAt"],
                updatedAt: row["updatedAt"], searchText: row["searchText"])
        }
    }

    func tagNames(_ id: UUID) throws -> [String] {
        try reader().read {
            try String.fetchAll(
                $0, sql: "SELECT tag.name FROM itemTag JOIN tag ON tag.id = itemTag.tagId WHERE itemId = ? ORDER BY tag.name",
                arguments: [id.uuidString])
        }
    }

    func strings(_ sql: String, _ arguments: StatementArguments = []) throws -> [String] {
        try reader().read { try String.fetchAll($0, sql: sql, arguments: arguments) }
    }

    func tagNames(_ n: Int) throws -> [String] { try tagNames(Store.id(n)) }
}

private func failure<T>(_ result: FlotsamResult<T>) -> ErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

@Suite struct OrganizeStorageTests {
    // MARK: Pin (FR-004-01)

    @Test("FR-004-01 toggle with a mixed selection pins all, then unpins all, and stamps the grace on unpin")
    func pinToggleMixedSelection() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, pinned: true), Spec(n: 2)])

        #expect(try await store.database.togglePinned(ids: [Store.id(1), Store.id(2)]).get() == true)
        #expect(try store.snapshot(1)?.pinned == true)
        #expect(try store.snapshot(2)?.pinned == true)

        store.clock.advance(ms: 1_000)
        #expect(try await store.database.togglePinned(ids: [Store.id(1), Store.id(2)]).get() == false)
        #expect(try store.snapshot(1)?.pinned == false)
        #expect(try store.snapshot(2)?.pinned == false)
        #expect(try store.exemptReleasedAt(1) == store.clock.millis)
    }

    @Test("FR-004-01 a missing id is skipped and the rest still toggle")
    func pinSkipsMissingItem() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1))
        #expect(try await store.database.togglePinned(ids: [Store.id(1), Store.id(99)]).get() == true)
        #expect(try store.snapshot(1)?.pinned == true)
    }

    // MARK: Tag names and limits (FR-004-02)

    @Test("FR-004-02 names: trimmed, 1 to 32, unique ignoring case and accents, no control characters")
    func tagNameRules() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        let db = store.database

        _ = try await db.createTag(name: "  Work  ").get()
        #expect(try store.strings("SELECT name FROM tag") == ["Work"])
        #expect(failure(await db.createTag(name: "work")) == .orgVal001)
        #expect(failure(await db.createTag(name: String(repeating: "a", count: 33))) == .orgVal001)
        #expect(failure(await db.createTag(name: "")) == .orgVal001)
        #expect(failure(await db.createTag(name: "     ")) == .orgVal001)
        #expect(failure(await db.createTag(name: "a\tb")) == .orgVal001)
        _ = try await db.createTag(name: String(repeating: "a", count: 32)).get()
        _ = try await db.createTag(name: "Résumé").get()
        #expect(failure(await db.createTag(name: "resume")) == .orgVal001)
        #expect(try store.count("tag") == 3)
    }

    @Test("FR-004-02 a new tag is gray unless a colour is given")
    func tagDefaultColour() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        _ = try await store.database.createTag(name: "a").get()
        _ = try await store.database.createTag(name: "b", color: .red).get()
        let colours = try store.strings("SELECT color FROM tag ORDER BY name")
        #expect(colours == ["gray", "red"])
    }

    @Test("FR-004-02 the 101st tag is ORG-LIM-002")
    func tagCeiling() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        for n in 1...100 { _ = try await store.database.createTag(name: "tag \(n)").get() }
        #expect(failure(await store.database.createTag(name: "one more")) == .orgLim002)
        #expect(try store.count("tag") == 100)
    }

    @Test("FR-004-02 the 11th tag on an item is ORG-LIM-001 and the action changes nothing")
    func perItemCeiling() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1), Spec(n: 2)])
        for n in 1...10 {
            let tag = try await store.database.createTag(name: "t\(n)").get()
            _ = try await store.database.toggleTag(id: tag, on: [Store.id(1)]).get()
        }
        let eleventh = try await store.database.createTag(name: "t11").get()

        // item 2 is clean, item 1 is full: the whole action is rejected, item 2 gets nothing
        #expect(failure(await store.database.toggleTag(id: eleventh, on: [Store.id(2), Store.id(1)])) == .orgLim001)
        #expect(try store.tagNames(2) == [])
        #expect(try store.tagNames(1).count == 10)

        // create-and-apply is one action: no tag is left behind when applying fails
        #expect(failure(await store.database.createTagAndApply(name: "t12", to: [Store.id(1)])) == .orgLim001)
        #expect(try store.count("tag") == 11)
    }

    // MARK: Assignment (FR-004-03)

    @Test("FR-004-03 mixed state applies to all on toggle, toggling again removes from all, and tags are searchable")
    func toggleMixed() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1), Spec(n: 2), Spec(n: 3)])
        let tag = try await store.database.createTag(name: "Zebra").get()
        let ids = [Store.id(1), Store.id(2), Store.id(3)]
        _ = try await store.database.toggleTag(id: tag, on: [Store.id(1)]).get()
        #expect(try await store.database.tagMembership(of: ids).get() == [tag: 1])

        #expect(try await store.database.toggleTag(id: tag, on: ids).get() == true)
        #expect(try await store.database.tagMembership(of: ids).get() == [tag: 3])
        #expect(try store.snapshot(2)?.searchText.contains("zebra") == true)

        #expect(try await store.database.toggleTag(id: tag, on: ids).get() == false)
        #expect(try await store.database.tagMembership(of: ids).get() == [:])
        #expect(try store.snapshot(2)?.searchText.contains("zebra") == false)
    }

    @Test("FR-004-03 create-and-apply makes the tag and applies it in one action")
    func createAndApply() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1), Spec(n: 2)])
        _ = try await store.database.createTagAndApply(name: "New", to: [Store.id(1), Store.id(2)]).get()
        #expect(try store.tagNames(1) == ["New"])
        #expect(try store.tagNames(2) == ["New"])
    }

    // MARK: Management (FR-004-04)

    @Test("FR-004-04 rename and recolour keep order and re-index; delete removes the tag and keeps the items")
    func renameRecolourDelete() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: hourMs), Spec(n: 2, ageMs: 2 * hourMs)])
        let tag = try await store.database.createTag(name: "Old").get()
        let other = try await store.database.createTag(name: "Other").get()
        _ = try await store.database.toggleTag(id: tag, on: [Store.id(1), Store.id(2)]).get()
        let before = try store.snapshot(1)

        #expect(failure(await store.database.renameTag(id: tag, to: "other")) == .orgVal001)
        #expect(try await store.database.renameTag(id: tag, to: "OLD").get() == true)
        #expect(try await store.database.renameTag(id: tag, to: "Fresh").get() == true)
        #expect(try await store.database.recolorTag(id: tag, to: .purple).get() == true)
        #expect(try store.tagNames(2) == ["Fresh"])
        #expect(try store.snapshot(1)?.searchText.contains("fresh") == true)
        #expect(try store.snapshot(1)?.lastCopiedAt == before?.lastCopiedAt)
        #expect(try store.strings("SELECT color FROM tag WHERE id = ?", [tag]) == ["purple"])

        #expect(try await store.database.deleteTag(id: tag).get() == 2)
        #expect(try store.presentIds() == [1, 2])
        #expect(try store.tagNames(1) == [])
        #expect(try store.snapshot(1)?.searchText.contains("fresh") == false)
        #expect(try await store.database.renameTag(id: 12345, to: "x").get() == false)
        _ = other
    }

    // MARK: Notes (FR-004-06)

    @Test("FR-004-06 a note is stored and found by search; only zero-length removes; whitespace is stored literally")
    func noteRules() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1))

        #expect(try await store.database.setNote("Remember The Milk", for: Store.id(1)).get() == true)
        #expect(try store.snapshot(1)?.note == "Remember The Milk")
        #expect(try store.snapshot(1)?.searchText.contains("remember the milk") == true)

        #expect(try await store.database.setNote("   ", for: Store.id(1)).get() == true)
        #expect(try store.snapshot(1)?.note == "   ")

        #expect(try await store.database.setNote("", for: Store.id(1)).get() == true)
        #expect(try store.snapshot(1)?.note == nil)
        #expect(try store.snapshot(1)?.searchText.contains("milk") == false)

        _ = try await store.database.setNote("x", for: Store.id(1)).get()
        #expect(try await store.database.setNote(nil, for: Store.id(1)).get() == true)
        #expect(try store.snapshot(1)?.note == nil)
        #expect(try await store.database.setNote("x", for: Store.id(99)).get() == false)
    }

    @Test("FR-004-06 the note reads back exactly as stored; none and a missing item read as nil")
    func noteReadBack() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1))
        #expect(try await store.database.note(of: Store.id(1)).get() == nil)
        _ = try await store.database.setNote("  two\nlines ", for: Store.id(1)).get()
        #expect(try await store.database.note(of: Store.id(1)).get() == "  two\nlines ")
        #expect(try await store.database.note(of: Store.id(99)).get() == nil)
    }

    @Test("FR-004-06 2,000 characters are accepted, 2,001 are ORG-VAL-002 and leave the note as it was")
    func noteCeiling() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1))
        _ = try await store.database.setNote(String(repeating: "n", count: 2000), for: Store.id(1)).get()
        #expect(failure(await store.database.setNote(String(repeating: "n", count: 2001), for: Store.id(1))) == .orgVal002)
        #expect(try store.snapshot(1)?.note?.count == 2000)
    }

    // MARK: Edit text (FR-004-07, FR-004-08)

    @Test("FR-004-07 saving removes RTF and its blob, re-detects the kind, and leaves dates, tags, pin and note alone")
    func editRichText() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        var spec = Spec(n: 1, kind: .richText, ageMs: 5 * hourMs, pinned: true, text: "old text")
        spec.blobs = 1
        spec.repBytes = 9
        try await store.insert(spec)
        _ = try await store.database.createTagAndApply(name: "keep", to: [Store.id(1)]).get()
        _ = try await store.database.setNote("note", for: Store.id(1)).get()
        let before = try #require(try store.snapshot(1))
        store.clock.advance(ms: 5_000)
        #expect(store.exists(store.blobURL(1, 1)))

        let kind = try await store.database.editText(id: Store.id(1), to: "https://x.y", classifiers: fakeClassifiers).get()

        #expect(kind == .link)
        let after = try #require(try store.snapshot(1))
        #expect(after.kind == "link")
        #expect(after.plainText == "https://x.y")
        #expect(after.contentKey == "edit:https://x.y")
        #expect(after.createdAt == before.createdAt)
        #expect(after.lastCopiedAt == before.lastCopiedAt)
        #expect(after.updatedAt == store.clock.millis)
        #expect(after.pinned && after.note == "note")
        #expect(try store.tagNames(1) == ["keep"])
        #expect(try store.representationCount(1) == 0)
        #expect(!store.exists(store.blobURL(1, 1)))
        #expect(after.searchText.contains("https://x.y"))
    }

    @Test("FR-004-07 a non-text kind and whitespace-only text are ORG-VAL-003; text over the ceiling is ORG-LIM-003")
    func editRejections() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, kind: .image), Spec(n: 2, text: "keep me")])

        #expect(failure(await store.database.editText(id: Store.id(1), to: "words", classifiers: fakeClassifiers)) == .orgVal003)
        #expect(failure(await store.database.editText(id: Store.id(2), to: " \n\t ", classifiers: fakeClassifiers)) == .orgVal003)
        #expect(failure(await store.database.editText(id: Store.id(2), to: "", classifiers: fakeClassifiers)) == .orgVal003)
        let oversize = String(repeating: "a", count: IngestLimits.maxTextBytes + 1)
        #expect(failure(await store.database.editText(id: Store.id(2), to: oversize, classifiers: fakeClassifiers)) == .orgLim003)
        #expect(try store.snapshot(2)?.plainText == "keep me")
        #expect(try await store.database.editText(id: Store.id(99), to: "x", classifiers: fakeClassifiers).get() == nil)
    }

    @Test("FR-004-08 an edit that equals another item's text keeps both rows")
    func editMakesDuplicate() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, text: "alpha"), Spec(n: 2, text: "beta")])
        _ = try await store.database.editText(id: Store.id(2), to: "alpha", classifiers: fakeClassifiers).get()
        _ = try await store.database.editText(id: Store.id(1), to: "alpha", classifiers: fakeClassifiers).get()
        #expect(try store.presentIds() == [1, 2])
        #expect(try store.snapshot(1)?.contentKey == store.snapshot(2)?.contentKey)
    }

    // MARK: Ungroup (FR-004-11)

    private func bundleStore() async throws -> Store {
        let store = try await Store.make()
        var bundle = Spec(n: 1, kind: .bundle, ageMs: hourMs, createdAgeMs: 2 * hourMs, pinned: true)
        bundle.members = [("/a/one.txt", false), ("/a/two", true), ("/a/three.png", false), ("/a/four.pdf", false)]
        try await store.insert([bundle, Spec(n: 2, ageMs: 10 * hourMs)])
        _ = try await store.database.createTagAndApply(name: "x", to: [Store.id(1)]).get()
        _ = try await store.database.setNote("bundle note", for: Store.id(1)).get()
        return store
    }

    @Test("FR-004-11 one item per member in original order, tags copied, note and pin left behind, bundle gone")
    func ungroupBundle() async throws {
        let store = try await bundleStore()
        defer { store.cleanUp() }
        let original = try #require(try store.snapshot(1))

        let created = try await store.database.ungroup(bundle: Store.id(1), classifiers: fakeClassifiers).get()

        #expect(created.count == 4)
        #expect(try store.snapshot(1) == nil)
        #expect(try store.count("bundleMember") == 4)
        let snapshots = try created.map { try #require(try store.snapshot($0)) }
        #expect(snapshots.map(\.kind) == ["file", "folder", "file", "file"])
        #expect(snapshots.map(\.contentKey) == ["file:/a/one.txt", "file:/a/two", "file:/a/three.png", "file:/a/four.pdf"])
        #expect(snapshots.map(\.lastCopiedAt) == (0..<4).map { original.lastCopiedAt - Int64($0) })
        #expect(snapshots.allSatisfy { $0.createdAt == original.createdAt && !$0.pinned && $0.note == nil })
        #expect(try created.allSatisfy { try store.tagNames($0) == ["x"] })

        // Recent order: members in their original order, ahead of the older unrelated item
        let order = try store.strings("SELECT id FROM item ORDER BY lastCopiedAt DESC")
        #expect(order == (created + [Store.id(2)]).map(\.uuidString))
    }

    @Test("FR-004-11 a failure on the 3rd insert leaves the bundle, its members, tags and note untouched")
    func ungroupIsAtomic() async throws {
        let store = try await bundleStore()
        defer { store.cleanUp() }
        try await store.database.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER inject_failure BEFORE INSERT ON item WHEN NEW.contentKey = 'file:/a/three.png'
                BEGIN SELECT RAISE(ABORT, 'injected'); END
                """)
        }
        let before = try store.snapshot(1)

        let result = await store.database.ungroup(bundle: Store.id(1), classifiers: fakeClassifiers)

        #expect(failure(result) == .stoDb001)
        #expect(try store.presentIds() == [1, 2])
        #expect(try store.snapshot(1) == before)
        #expect(try store.count("bundleMember") == 4)
        #expect(try store.tagNames(1) == ["x"])
    }

    @Test("FR-004-11 ungrouping something that is not a bundle is rejected; a missing bundle is an empty result")
    func ungroupGuards() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1))
        #expect(failure(await store.database.ungroup(bundle: Store.id(1), classifiers: fakeClassifiers)) == .sysInt001)
        #expect(try await store.database.ungroup(bundle: Store.id(99), classifiers: fakeClassifiers).get() == [])
        #expect(try store.presentIds() == [1])
    }

    // MARK: Events (FR-004-13)

    @Test("FR-004-13 organise actions publish itemsChanged; ungroup also publishes itemsDeleted for the bundle")
    func eventsPublished() async throws {
        let store = try await bundleStore()
        defer { store.cleanUp() }
        let recorder = EventCollector(store.database.events)

        _ = try await store.database.togglePinned(ids: [Store.id(2)]).get()
        #expect(recorder.events.contains(.itemsChanged))
        _ = try await store.database.ungroup(bundle: Store.id(1), classifiers: fakeClassifiers).get()
        #expect(recorder.events.contains(.itemsDeleted([Store.id(1)])))
    }
}
