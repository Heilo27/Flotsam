import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-004 8T contract tests, slice Tags (oracle .claude/oracle/frd-004-contract.json). Package half of each OC: the
// Storage commands behind the tag editor and the sidebar. The popover, the inline error view and the sidebar rows are
// App-target UI and are listed in FRD004ContractTestsGaps.swift. Expected values are literals; state is read back
// through a second read-only connection (Store.reader), never through the connection that wrote it.

private func tagCode<T>(_ result: FlotsamResult<T>) -> ErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

private func message(_ code: ErrorCode) -> String? { FlotsamStrings.text(forKey: code.catalogueKey) }

private extension Store {
    func tagNames() throws -> [String] {
        try reader().read { try String.fetchAll($0, sql: "SELECT name FROM tag ORDER BY name") }
    }

    func tagColor(_ id: Int64) throws -> String? {
        try reader().read { try String?.fetchOne($0, sql: "SELECT color FROM tag WHERE id = ?", arguments: [id]) ?? nil }
    }

    /// Tag names carried by item n, read through the second connection.
    func tagsOn(_ n: Int) throws -> [String] {
        try reader().read {
            try String.fetchAll(
                $0, sql: "SELECT tag.name FROM itemTag JOIN tag ON tag.id = itemTag.tagId WHERE itemTag.itemId = ? ORDER BY tag.name",
                arguments: [Store.id(n).uuidString])
        }
    }

    /// Item numbers (trailing digits of the fixture id) in the order the public listing returns them.
    func order(_ filter: LibraryFilter = .all, sort: LibrarySort = .recent, text: String = "") async throws -> [Int] {
        try await database.listing(LibraryQuery(filter: filter, text: text, sort: sort)).ids.map { Int(String($0.uuidString.suffix(12)))! }
    }

    func install(_ trigger: String) async throws { try await database.pool.write { try $0.execute(sql: trigger) } }
}

@Suite struct FRD004ContractTestsTags {

    // OC-4009. Red if createTag stops comparing names case-insensitively (the second 'work' would be created).
    @Test("OC-4009 given tag 'Work', when a tag 'work' is created, then ORG-VAL-001 with its message, still one tag, named 'Work'")
    func duplicateByCaseRejected() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        _ = try await store.database.createTag(name: "Work").get()

        let result = await store.database.createTag(name: "work")

        #expect(tagCode(result) == .orgVal001)
        #expect(message(.orgVal001) == "Tag names must be 1 to 32 characters and unique.")
        #expect(try store.count("tag") == 1)
        #expect(try store.tagNames() == ["Work"])
    }

    // OC-4012. Red if renameTag accepts an empty or whitespace-only name.
    @Test("OC-4012 given tag 'alpha', when renamed to '' and to '   ', then each is ORG-VAL-001 and the tag is still 'alpha'")
    func renameToEmptyRejected() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        let alpha = try await store.database.createTag(name: "alpha").get()

        let empty = await store.database.renameTag(id: alpha, to: "")
        let spaces = await store.database.renameTag(id: alpha, to: "   ")

        #expect(tagCode(empty) == .orgVal001)
        #expect(tagCode(spaces) == .orgVal001)
        #expect(try store.tagNames() == ["alpha"])
        #expect(try store.count("tag") == 1)
    }

    // OC-4013. Red if uniqueness folds case but not diacritics ('resume' would be accepted next to 'Résumé').
    @Test("OC-4013 given tag 'Résumé', when a tag 'resume' is created, then ORG-VAL-001 and still one tag")
    func duplicateByDiacriticRejected() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        _ = try await store.database.createTag(name: "Résumé").get()

        let result = await store.database.createTag(name: "resume")

        #expect(tagCode(result) == .orgVal001)
        #expect(try store.count("tag") == 1)
        #expect(try store.tagNames() == ["Résumé"])
    }

    // OC-4014. Red if the name is stored untrimmed, or if the duplicate check runs on the untrimmed text.
    @Test("OC-4014 given no tag, when '  client-a  ' is created, then one tag named 'client-a' exists and 'client-a' again is ORG-VAL-001")
    func nameIsTrimmedBeforeStoringAndComparing() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }

        _ = try await store.database.createTag(name: "  client-a  ").get()
        let again = await store.database.createTag(name: "client-a")

        #expect(try store.tagNames() == ["client-a"])
        #expect(try store.count("tag") == 1)
        #expect(tagCode(again) == .orgVal001)
        #expect(try store.count("tag") == 1)
    }

    // OC-4015. Red if the control-character rule is dropped from TagNameRule (a name with an inner tab/newline is stored).
    @Test("OC-4015 given no tags, when names with an inner tab or newline are created, then each is ORG-VAL-001 and no tag exists")
    func controlCharactersRejected() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }

        let tab = await store.database.createTag(name: "bad\tname")
        let newline = await store.database.createTag(name: "bad\nname")

        #expect(tagCode(tab) == .orgVal001)
        #expect(tagCode(newline) == .orgVal001)
        #expect(try store.count("tag") == 0)
    }

    // OC-4016. Red if the default colour changes from gray.
    @Test("OC-4016 given no tags, when 'x' is created without a colour, then its stored colour is gray")
    func defaultColourIsGray() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }

        let id = try await store.database.createTag(name: "x").get()

        #expect(try store.tagColor(id) == "gray")
        #expect(try store.count("tag") == 1)
    }

    // OC-4018. Red if the per-item ceiling check is removed or moved to `<=` 10 (the 11th link would be written).
    @Test("OC-4018 given an item with exactly 10 tags, when an 11th is toggled on, then ORG-LIM-001, still 10 tags, the 11th has 0 items")
    func eleventhTagOnItemRejected() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 1000)])
        var ids: [Int64] = []
        for i in 1...11 { ids.append(try await store.database.createTag(name: "t\(i)").get()) }
        for tag in ids.prefix(10) { _ = try await store.database.toggleTag(id: tag, on: [Store.id(1)]).get() }
        #expect(try store.tagsOn(1).count == 10)

        let result = await store.database.toggleTag(id: ids[10], on: [Store.id(1)])

        #expect(tagCode(result) == .orgLim001)
        #expect(message(.orgLim001) == "An item can have up to 10 tags.")
        #expect(try store.tagsOn(1).count == 10)
        #expect(try store.tagsOn(1).contains("t11") == false)
        #expect(try store.scalarCount("SELECT COUNT(*) FROM itemTag WHERE tagId = ?", ids[10]) == 0)
    }

    // OC-4019. Red if the 100-tag ceiling is checked with `>` 100 (a 101st tag would be created).
    @Test("OC-4019 given exactly 100 tags, when a 101st is created, then ORG-LIM-002 and exactly 100 tags remain")
    func hundredFirstTagRejected() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        for i in 1...100 { _ = try await store.database.createTag(name: "tag\(i)").get() }
        #expect(try store.count("tag") == 100)

        let result = await store.database.createTag(name: "one-too-many")

        #expect(tagCode(result) == .orgLim002)
        #expect(message(.orgLim002) == "You can have up to 100 tags.")
        #expect(try store.count("tag") == 100)
        #expect(try store.tagNames().contains("one-too-many") == false)
    }

    // OC-4025. Red if toggle treats a mixed selection as "remove" (the first toggle would drop T from the one item).
    @Test("OC-4025 given 3 items and T on exactly one, when T is toggled twice, then mixed (1), all 3 (+2), then none")
    func mixedStateTogglesAddThenRemove() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...3).map { Spec(n: $0, ageMs: Int64($0) * 1000) })
        let tag = try await store.database.createTag(name: "T").get()
        _ = try await store.database.toggleTag(id: tag, on: [Store.id(2)]).get()
        let ids = [Store.id(1), Store.id(2), Store.id(3)]
        #expect(try await store.database.tagMembership(of: ids).get()[tag] == 1)

        let first = try await store.database.toggleTag(id: tag, on: ids).get()

        #expect(first == true)
        #expect(try await store.database.tagMembership(of: ids).get()[tag] == 3)
        #expect(try await store.database.sidebarCounts().get().tags.first { $0.id == tag }?.count == 3)

        let second = try await store.database.toggleTag(id: tag, on: ids).get()

        #expect(second == false)
        #expect(try await store.database.tagMembership(of: ids).get()[tag] == nil)
        #expect(try store.count("itemTag") == 0)
        #expect(try store.count("item") == 3)
    }

    // OC-4031. Red if deleteTag reports a wrong item count or leaves the tag row or deletes items.
    @Test("OC-4031 given tag T on zero items and 3 items, when T is deleted, then 0 items affected, T gone, 3 items remain")
    func deleteUnusedTag() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...3).map { Spec(n: $0, ageMs: Int64($0) * 1000) })
        let unused = try await store.database.createTag(name: "unused").get()
        _ = try await store.database.createTag(name: "kept").get()

        let affected = try await store.database.deleteTag(id: unused).get()

        #expect(affected == 0)
        #expect(try store.tagNames() == ["kept"])
        #expect(try store.presentIds() == [1, 2, 3])
    }

    // OC-4032. Red if rename writes a new tag row (chips keep the old name) or touches the item order.
    @Test("OC-4032 given tag 'old' on 3 of 4 items, when renamed 'new', then those items read 'new', none 'old', order unchanged")
    func renameShowsEverywhereAndKeepsOrder() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...4).map { Spec(n: $0, ageMs: Int64($0) * 1000) })
        let tag = try await store.database.createTag(name: "old").get()
        _ = try await store.database.toggleTag(id: tag, on: [Store.id(1), Store.id(2), Store.id(4)]).get()
        let before = try await store.order()

        let renamed = try await store.database.renameTag(id: tag, to: "new").get()

        #expect(renamed == true)
        #expect(try store.tagNames() == ["new"])
        #expect(try store.tagsOn(1) == ["new"])
        #expect(try store.tagsOn(2) == ["new"])
        #expect(try store.tagsOn(3) == [])
        #expect(try store.tagsOn(4) == ["new"])
        #expect(try await store.order() == before)
        #expect(before == [1, 2, 3, 4])
    }

    // OC-4033. Red if recolor writes the wrong column or reorders items.
    @Test("OC-4033 given gray tag T on items, when recoloured blue, then the stored colour and the sidebar colour are blue, order unchanged")
    func recolourReachesSidebarAndKeepsOrder() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...3).map { Spec(n: $0, ageMs: Int64($0) * 1000) })
        let tag = try await store.database.createTag(name: "T").get()
        _ = try await store.database.toggleTag(id: tag, on: [Store.id(1), Store.id(3)]).get()
        #expect(try store.tagColor(tag) == "gray")
        let before = try await store.order()

        let changed = try await store.database.recolorTag(id: tag, to: .blue).get()

        #expect(changed == true)
        #expect(try store.tagColor(tag) == "blue")
        #expect(try await store.database.sidebarCounts().get().tags.first { $0.id == tag }?.color == "blue")
        #expect(try await store.order() == before)
        #expect(try store.count("tag") == 1)
    }

    // OC-4034. Red if rename skips the duplicate check (b would become 'A' next to 'a').
    @Test("OC-4034 given tags 'a' and 'b', when 'b' is renamed 'A', then ORG-VAL-001 and 'b' keeps its name")
    func renameToExistingNameRejected() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        _ = try await store.database.createTag(name: "a").get()
        let b = try await store.database.createTag(name: "b").get()

        let result = await store.database.renameTag(id: b, to: "A")

        #expect(tagCode(result) == .orgVal001)
        #expect(try store.tagNames() == ["a", "b"])
        #expect(try store.count("tag") == 2)
    }

    // OC-4035. Red if the search index is not refreshed when a tag is applied (X would not be found by its tag name).
    @Test("OC-4035 given items 1 and 2 and tag 'zebra-unique' on item 1 only, when searched, then exactly item 1 is found")
    func tagNameIsSearchable() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 1000, text: "alpha"), Spec(n: 2, ageMs: 2000, text: "beta")])
        let tag = try await store.database.createTag(name: "zebra-unique").get()
        #expect(try await store.order(text: "zebra-unique") == [])

        _ = try await store.database.toggleTag(id: tag, on: [Store.id(1)]).get()

        #expect(try await store.order(text: "zebra-unique") == [1])
        #expect(try await store.order() == [1, 2])
    }

    // OC-4036. Red if the tag filter returns every item, or drops one that carries the tag.
    @Test("OC-4036 given tag T on exactly 3 of 6 items, when T is selected, then exactly those 3 are listed and the total is 3")
    func tagFilterListsExactlyTheTaggedItems() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...6).map { Spec(n: $0, ageMs: Int64($0) * 1000) })
        let tag = try await store.database.createTag(name: "T").get()
        _ = try await store.database.toggleTag(id: tag, on: [Store.id(2), Store.id(4), Store.id(5)]).get()

        let page = try await store.database.items(matching: LibraryQuery(filter: .tag(tag))).get()

        #expect(page.totalCount == 3)
        #expect(page.rows.map(\.id) == [Store.id(2), Store.id(4), Store.id(5)])
        #expect(page.rows.allSatisfy { $0.tagNames == ["T"] })
        #expect(try await store.order() == [1, 2, 3, 4, 5, 6])
    }

    // OC-4088. Red if the tag filter falls back to All for a tag with no items.
    @Test("OC-4088 given tag T on zero items and 2 items, when T is selected, then zero rows and a total of 0")
    func emptyTagFilterIsEmpty() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 1000), Spec(n: 2, ageMs: 2000)])
        let tag = try await store.database.createTag(name: "T").get()

        let page = try await store.database.items(matching: LibraryQuery(filter: .tag(tag))).get()

        #expect(page.rows.isEmpty)
        #expect(page.totalCount == 0)
        #expect(try await store.database.items(matching: LibraryQuery(filter: .all)).get().totalCount == 2)
    }

    // OC-4104. Red if any storage path logs a tag name or a note body (public or private text). Weaker than the other
    // tests: it can only fail when a log line carries the marker; a fault is injected first so the sink is in use.
    @Test("OC-4104 given a tag and a note with unique markers, when the tag is created, renamed, deleted and the note edited, then no log line holds a marker")
    func contentNeverReachesTheLog() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 1000)])
        let tagMarker = "zqtagmarker7f3a"
        let renamedMarker = "zqrenamedmarker91c2"
        let noteMarker = "zqnotemarker55d0"
        try await store.install("""
            CREATE TRIGGER inject_failure BEFORE INSERT ON tag BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        let failed = await store.database.createTag(name: tagMarker)
        #expect(tagCode(failed) == .stoDb001)
        try await store.database.pool.write { try $0.execute(sql: "DROP TRIGGER inject_failure") }

        let tag = try await store.database.createTag(name: tagMarker).get()
        _ = try await store.database.renameTag(id: tag, to: renamedMarker).get()
        _ = try await store.database.setNote(noteMarker, for: Store.id(1)).get()
        _ = try await store.database.setNote("replacement without marker", for: Store.id(1)).get()
        _ = try await store.database.deleteTag(id: tag).get()

        for marker in [tagMarker, renamedMarker, noteMarker] {
            #expect(store.logs.lines(containing: [marker]).isEmpty)
        }
        #expect(try store.tagNames() == [])
        #expect(try store.count("item") == 1)
    }
}

private extension Store {
    func scalarCount(_ sql: String, _ value: Int64) throws -> Int {
        try reader().read { try Int.fetchOne($0, sql: sql, arguments: [value]) ?? -1 }
    }
}
