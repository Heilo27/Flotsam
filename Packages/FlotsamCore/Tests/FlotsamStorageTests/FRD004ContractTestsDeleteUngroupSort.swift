import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-004 8T contract tests, slice DeleteUngroupSort (oracle .claude/oracle/frd-004-contract.json): delete (AC-004-09),
// Ungroup (AC-004-10, FR-004-11), filters (AC-004-11, FR-004-10), sort (AC-004-12, BR-5) and the tag-write failure
// (FR-004-14). Package half of each OC: the Storage commands and queries. The confirm dialog, the keystrokes and the
// selection model are App/Library targets (FRD004ContractTestsLibrary.swift, FRD004ContractTestsGaps.swift). Expected
// values are literals; state is read back through a second read-only connection (Store.reader) or the public query API.

/// Faked the way the capture rules behave for a single file: a file is `.file`, a directory `.folder`, and the dedupe
/// key is derived from the path alone. Real ContentKey parity is FR-001-15, covered elsewhere.
private let fileClassifiers = ItemClassifiers(
    editedText: { text in ItemClassification(kind: .text, contentKey: "edit:" + text) },
    fileMember: { path, isDirectory in
        ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path)
    })

private func errorCode<T>(_ result: FlotsamResult<T>) -> ErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

private func message(_ code: ErrorCode) -> String? { FlotsamStrings.text(forKey: code.catalogueKey) }

private func number(_ id: UUID) -> Int { Int(String(id.uuidString.suffix(12)))! }

private extension Store {
    /// Item numbers (trailing digits of the fixture id) in the order the public listing returns them.
    func order(_ filter: LibraryFilter = .all, sort: LibrarySort = .recent, text: String = "") async throws -> [Int] {
        try await database.listing(LibraryQuery(filter: filter, text: text, sort: sort)).ids.map(number)
    }

    /// First page of rows for a query, as the Library shows them.
    func rows(_ filter: LibraryFilter = .all, sort: LibrarySort = .recent, text: String = "") async throws -> [ItemRow] {
        try await database.items(matching: LibraryQuery(filter: filter, text: text, sort: sort)).get().rows
    }

    /// How many regular files sit under a directory of the data folder.
    func fileCount(in directory: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        return walker.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
    }

    func setSource(_ n: Int, bundle: String?, name: String?) async throws {
        try await database.pool.write {
            try $0.execute(
                sql: "UPDATE item SET sourceBundleId = ?, sourceName = ? WHERE id = ?",
                arguments: [bundle, name, Store.id(n).uuidString])
        }
    }

    func install(_ trigger: String) async throws { try await database.pool.write { try $0.execute(sql: trigger) } }

    func tagId(_ name: String) throws -> Int64 {
        try reader().read { try Int64.fetchOne($0, sql: "SELECT id FROM tag WHERE name = ?", arguments: [name])! }
    }
}

@Suite struct FRD004ContractTestsDeleteUngroupSort {

    // MARK: Delete (AC-004-09)

    // OC-4062. Red if delete leaves the row (or its search terms), removes a neighbour, or reports the wrong ids.
    @Test("OC-4062 given an unpinned item X among 3 others, when X is deleted, then it is gone, the count drops 4 to 3, searching its unique text finds nothing and the others remain")
    func deleteRemovesTheItemAndItsSearchTerms() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 1000, text: "alpha"), Spec(n: 2, ageMs: 2000, text: "zzuniquexray"), Spec(n: 3, ageMs: 3000, text: "gamma"), Spec(n: 4, ageMs: 4000, text: "delta")])
        #expect(try await store.order(text: "zzuniquexray") == [2])
        #expect(try store.count("item") == 4)

        let removed = try await store.database.delete(ids: [Store.id(2)]).get()

        #expect(removed == [Store.id(2)])
        #expect(try store.count("item") == 3)
        #expect(try store.presentIds() == [1, 3, 4])
        #expect(try await store.order(text: "zzuniquexray") == [])
        #expect(try await store.order() == [1, 3, 4])
    }

    // OC-4062 (boundary). Red if deleting an id that is not there removes anything else or reports it as removed.
    @Test("OC-4062 given 2 items, when an id that does not exist is deleted, then nothing is removed and the result is empty")
    func deleteOfMissingIdChangesNothing() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1), Spec(n: 2)])

        let removed = try await store.database.delete(ids: [Store.id(99)]).get()

        #expect(removed == [])
        #expect(try store.presentIds() == [1, 2])
    }

    // OC-4068. Red if delete leaves an image blob or a thumbnail on disk, or removes the neighbour's files.
    @Test("OC-4068 given image X with a blob and two thumbnails and image Y with the same, when X is deleted, then X's three files are gone, blob and thumbnail file counts drop by exactly X's, and Y's files remain")
    func deleteRemovesBlobsAndThumbnails() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        var x = Spec(n: 1, kind: .image, ageMs: hourMs)
        x.blobs = 1
        x.repBytes = 9
        x.thumbs = true
        var y = Spec(n: 2, kind: .image, ageMs: 2 * hourMs)
        y.blobs = 1
        y.repBytes = 9
        y.thumbs = true
        try await store.insert([x, y])
        #expect(store.fileCount(in: store.blobsDir) == 2)
        #expect(store.fileCount(in: store.thumbsDir) == 4)

        _ = try await store.database.delete(ids: [Store.id(1)]).get()

        #expect(try store.presentIds() == [2])
        #expect(!store.exists(store.blobURL(1, 1)))
        #expect(!store.exists(store.thumbURL(1, 256)))
        #expect(!store.exists(store.thumbURL(1, 512)))
        #expect(store.fileCount(in: store.blobsDir) == 1)
        #expect(store.fileCount(in: store.thumbsDir) == 2)
        #expect(store.exists(store.blobURL(2, 1)))
        #expect(store.exists(store.thumbURL(2, 256)))
        #expect(try store.representationCount(1) == 0)
        #expect(try store.representationCount(2) == 1)
    }

    // MARK: Ungroup (AC-004-10, FR-004-11)

    /// Bundle 1 of four files f1..f4 (created 2 h ago, last copied 1 h ago) with tag 'x', a note and a pin, between a
    /// newer item 2 (30 min) and an older item 3 (10 h).
    private func bundleStore(hotkey: Int? = nil, source: (bundle: String, name: String)? = nil) async throws -> Store {
        let store = try await Store.make()
        var bundle = Spec(n: 1, kind: .bundle, ageMs: hourMs, createdAgeMs: 2 * hourMs, pinned: true, hotkey: hotkey)
        bundle.members = [("/a/f1.txt", false), ("/a/f2.txt", false), ("/a/f3.txt", false), ("/a/f4.txt", false)]
        try await store.insert([bundle, Spec(n: 2, ageMs: hourMs / 2, text: "newer"), Spec(n: 3, ageMs: 10 * hourMs, text: "older")])
        _ = try await store.database.createTagAndApply(name: "x", to: [Store.id(1)]).get()
        _ = try await store.database.setNote("bundle note", for: Store.id(1)).get()
        if let source { try await store.setSource(1, bundle: source.bundle, name: source.name) }
        return store
    }

    /// The single member path of each listed item, in the order given.
    private func memberPaths(_ store: Store, _ ids: [UUID]) throws -> [String] {
        try ids.map { id in
            try store.reader().read {
                try String.fetchAll($0, sql: "SELECT path FROM bundleMember WHERE itemId = ?", arguments: [id.uuidString]).joined(separator: "|")
            }
        }
    }

    // OC-4074. Red if the member order is reversed (lastCopiedAt offset flipped), a member is lost, the tag is not
    // carried, or the note or pin follow the members.
    @Test("OC-4074 given bundle B of f1..f4 with tag 'x', a note and a pin, when B is ungrouped, then B is gone, exactly 4 file items exist (count 3 to 6), Recent lists newer, f1, f2, f3, f4, older, each carries 'x' and none has a note or pin")
    func ungroupYieldsMembersInOrderWithTagsOnly() async throws {
        let store = try await bundleStore()
        defer { store.cleanUp() }
        #expect(try store.count("item") == 3)

        let created = try await store.database.ungroup(bundle: Store.id(1), classifiers: fileClassifiers).get()

        #expect(created.count == 4)
        #expect(try store.count("item") == 6)
        let bundleRows = try await store.reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE id = ?", arguments: [Store.id(1).uuidString]) }
        #expect(bundleRows == 0)
        let listed = try await store.database.listing(LibraryQuery(sort: .recent)).ids
        #expect(listed.count == 6)
        #expect(listed.first == Store.id(2))
        #expect(listed.last == Store.id(3))
        let middle = Array(listed[1...4])
        #expect(Set(middle) == Set(created))
        #expect(try memberPaths(store, middle) == ["/a/f1.txt", "/a/f2.txt", "/a/f3.txt", "/a/f4.txt"])
        let rows = try await store.rows().filter { created.contains($0.id) }
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.tagNames == ["x"] && !$0.isPinned && $0.kind == .file })
        let notes = try await store.reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE note IS NOT NULL") }
        #expect(notes == 0)
    }

    // OC-4077. Red if ungroup copies the hotkey onto a member (a badge would show and pressing H would paste a file).
    @Test("OC-4077 given bundle B with hotkey 7, when B is ungrouped, then no item holds a hotkey and no new row shows a shortcut badge")
    func ungroupLeavesNoHotkeyBehind() async throws {
        let store = try await bundleStore(hotkey: 7)
        defer { store.cleanUp() }
        #expect(try await store.reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE hotkeyCode IS NOT NULL") } == 1)
        #expect(try await store.rows().filter(\.hasShortcut).map(\.id) == [Store.id(1)])

        let created = try await store.database.ungroup(bundle: Store.id(1), classifiers: fileClassifiers).get()

        #expect(created.count == 4)
        #expect(try await store.reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE hotkeyCode IS NOT NULL") } == 0)
        #expect(try await store.rows().filter(\.hasShortcut).isEmpty)
        #expect(try await store.rows().filter { created.contains($0.id) }.count == 4)
    }

    // OC-4078. Red if the members lose the bundle's source or created date, or a folder member becomes a file item.
    @Test("OC-4078 given a bundle of one file and one folder from Finder created 2 hours ago, when ungrouped, then a file item and a folder item exist, both from Finder and both created 2 hours ago")
    func ungroupKeepsSourceAndCreatedDate() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        let start = store.clock.millis
        var bundle = Spec(n: 1, kind: .bundle, ageMs: hourMs, createdAgeMs: 2 * hourMs)
        bundle.members = [("/a/report.pdf", false), ("/a/Docs", true)]
        try await store.insert(bundle)
        try await store.setSource(1, bundle: "com.apple.finder", name: "Finder")

        let created = try await store.database.ungroup(bundle: Store.id(1), classifiers: fileClassifiers).get()

        #expect(created.count == 2)
        let rows = try await store.rows()
        #expect(rows.map(\.kind) == [.file, .folder])
        #expect(rows.map(\.sourceName) == ["Finder", "Finder"])
        #expect(try await store.database.listing(LibraryQuery(filter: .sourceApp(.bundle("com.apple.finder")))).ids.count == 2)
        let createdAts = try await store.reader().read { try Int64.fetchAll($0, sql: "SELECT createdAt FROM item") }
        #expect(createdAts == [start - 2 * hourMs, start - 2 * hourMs])
    }

    // MARK: Filters (AC-004-11, FR-004-10)

    // OC-4082. Red if the kind filter is combined with the tag (links without T would vanish) or the tag filter leaks
    // other kinds.
    @Test("OC-4082 given tag T on two links and one note item and a third link without T, when the T filter and then the Links filter are queried, then Links lists all 3 links including the one without T")
    func kindFilterIsNotCombinedWithTag() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([
            Spec(n: 1, kind: .link, ageMs: 1000, text: "https://a.example"), Spec(n: 2, kind: .link, ageMs: 2000, text: "https://b.example"),
            Spec(n: 3, kind: .link, ageMs: 3000, text: "https://c.example"), Spec(n: 4, ageMs: 4000, text: "plain"),
        ])
        let tag = try await store.database.createTagAndApply(name: "T", to: [Store.id(1), Store.id(2), Store.id(4)]).get()

        let tagged = try await store.order(.tag(tag))
        let links = try await store.order(.kind(.link))

        #expect(tagged == [1, 2, 4])
        #expect(links == [1, 2, 3])
        #expect(try await store.database.items(matching: LibraryQuery(filter: .kind(.link))).get().totalCount == 3)
    }

    // OC-4083. Red if search text is ignored under a tag filter (or the tag ignored under search).
    @Test("OC-4083 given tag T on 4 items of which 2 contain 'abc', and an untagged item containing 'abc', when T is selected and 'abc' is typed, then exactly the 2 tagged matches are listed, total 2 and no more than T's 4")
    func tagFilterAndSearchIntersect() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([
            Spec(n: 1, ageMs: 1000, text: "abc one"), Spec(n: 2, ageMs: 2000, text: "other two"), Spec(n: 3, ageMs: 3000, text: "three abc"),
            Spec(n: 4, ageMs: 4000, text: "four"), Spec(n: 5, ageMs: 5000, text: "abc untagged"),
        ])
        let tag = try await store.database.createTagAndApply(name: "T", to: (1...4).map { Store.id($0) }).get()
        let page = try await store.database.items(matching: LibraryQuery(filter: .tag(tag), text: "abc")).get()

        #expect(page.rows.map { number($0.id) } == [1, 3])
        #expect(page.totalCount == 2)
        #expect(page.rows.allSatisfy { $0.tagNames == ["T"] })
        #expect(try await store.order(.tag(tag)) == [1, 2, 3, 4])
        #expect(try await store.order(text: "abc") == [1, 3, 5])
        // Boundary: a search that matches nothing under the tag is empty, not the whole tag.
        #expect(try await store.order(.tag(tag), text: "nomatchzz") == [])
    }

    // OC-4085. Red if a source bucket is mixed with another (unknown vs another device) or a badge differs from the list.
    @Test("OC-4085 given 2 Safari items, 1 with no source and 3 from another device, when Safari, Unknown and Another device are selected, then each lists only its own items and the count equals the sidebar badge")
    func sourceBucketsListOnlyTheirOwnItems() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...6).map { Spec(n: $0, ageMs: Int64($0) * 1000) })
        try await store.setSource(1, bundle: "com.apple.Safari", name: "Safari")
        try await store.setSource(2, bundle: "com.apple.Safari", name: "Safari")
        try await store.setSource(3, bundle: nil, name: nil)
        try await store.setSource(4, bundle: nil, name: "Another device")
        try await store.setSource(5, bundle: nil, name: "Another device")
        try await store.setSource(6, bundle: nil, name: "Another device")

        let sidebar = try await store.database.sidebarCounts().get()

        #expect(try await store.order(.sourceApp(.bundle("com.apple.Safari"))) == [1, 2])
        #expect(try await store.order(.sourceApp(.unknown)) == [3])
        #expect(try await store.order(.sourceApp(.anotherDevice)) == [4, 5, 6])
        #expect(sidebar.apps.first { $0.identity == .bundle("com.apple.Safari") }?.count == 2)
        #expect(sidebar.apps.first { $0.identity == .unknown }?.count == 1)
        #expect(sidebar.apps.first { $0.identity == .anotherDevice }?.count == 3)
        #expect(sidebar.apps.count == 3)
    }

    // OC-4086. Red if the kind filter lists another kind (a screenshot under Images) or misses an image.
    @Test("OC-4086 given 2 images, a screenshot, a link and 2 texts, when Images is selected, then only the 2 images are listed and the sidebar badge is 2; a kind with no items lists nothing",
          arguments: [(ItemKind.image, [1, 2]), (.screenshot, [3]), (.link, [4]), (.color, [])])
    func kindFilterListsOnlyThatKind(kind: ItemKind, expected: [Int]) async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([
            Spec(n: 1, kind: .image, ageMs: 1000), Spec(n: 2, kind: .image, ageMs: 2000), Spec(n: 3, kind: .screenshot, ageMs: 3000),
            Spec(n: 4, kind: .link, ageMs: 4000, text: "https://a.example"), Spec(n: 5, ageMs: 5000), Spec(n: 6, ageMs: 6000),
        ])

        let listed = try await store.order(.kind(kind))

        #expect(listed == expected)
        #expect(try await store.database.sidebarCounts().get().kinds[kind] ?? 0 == expected.count)
        #expect(try await store.database.items(matching: LibraryQuery(filter: .kind(kind))).get().totalCount == expected.count)
    }

    // MARK: Sort (AC-004-12, FR-004-12, BR-5)

    // OC-4090. Red if Oldest sorts descending or on another key.
    @Test("OC-4090 given 6 items copied 1 to 6 hours ago, when sort is Oldest, then they list from the oldest copy to the newest")
    func oldestSortsByLastCopiedAscending() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 4, ageMs: 4 * hourMs), Spec(n: 1, ageMs: hourMs), Spec(n: 6, ageMs: 6 * hourMs), Spec(n: 3, ageMs: 3 * hourMs), Spec(n: 5, ageMs: 5 * hourMs), Spec(n: 2, ageMs: 2 * hourMs)])

        #expect(try await store.order(sort: .oldest) == [6, 5, 4, 3, 2, 1])
        #expect(try await store.order(sort: .recent) == [1, 2, 3, 4, 5, 6])
    }

    // OC-4091. Red if Most Used ties are not broken by newer copy first, or the primary key is not pasteCount.
    @Test("OC-4091 given 6 items pasted 0, 2, 5, 2, 0 and 1 times, when sort is Most Used, then they list by paste count descending and each equal pair lists the newer copy first")
    func mostUsedSortsByPasteCountThenRecency() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...6).map { Spec(n: $0, ageMs: Int64($0) * hourMs) })
        let pastes = [1: 0, 2: 2, 3: 5, 4: 2, 5: 0, 6: 1]
        for (n, times) in pastes { for _ in 0..<times { _ = try await store.database.recordPaste(of: Store.id(n)).get() } }

        #expect(try await store.order(sort: .mostUsed) == [3, 2, 4, 6, 1, 5])
    }

    // OC-4092. Red if A to Z is case-sensitive (Apple would sort before banana but 'apple' after cherry) or loses the tie-break.
    @Test("OC-4092 given 'banana', 'Apple', 'cherry' and 'apple' (apple copied later), when sort is A to Z, then the order is apple, Apple, banana, cherry")
    func alphabeticalIsCaseInsensitiveWithRecencyTieBreak() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([
            Spec(n: 1, ageMs: 1000, text: "banana"), Spec(n: 2, ageMs: 4000, text: "Apple"), Spec(n: 3, ageMs: 3000, text: "cherry"), Spec(n: 4, ageMs: 2000, text: "apple"),
        ])

        #expect(try await store.order(sort: .alphabetical) == [4, 2, 1, 3])
    }

    // OC-4094. Red if any sort floats pinned items to the top instead of placing them by the sort key.
    @Test("OC-4094 given 6 items of which echo and bravo are pinned, when each sort is applied, then every order is exactly the sort key's and the pinned items are not collected at the top")
    func pinnedItemsFollowTheSortKey() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([
            Spec(n: 1, ageMs: 1 * hourMs, text: "delta"), Spec(n: 2, ageMs: 2 * hourMs, text: "alpha"),
            Spec(n: 3, ageMs: 3 * hourMs, pinned: true, text: "echo"), Spec(n: 4, ageMs: 4 * hourMs, pinned: true, text: "bravo"),
            Spec(n: 5, ageMs: 5 * hourMs, text: "foxtrot"), Spec(n: 6, ageMs: 6 * hourMs, text: "charlie"),
        ])
        for (n, times) in [2: 3, 3: 1, 5: 2] { for _ in 0..<times { _ = try await store.database.recordPaste(of: Store.id(n)).get() } }

        #expect(try await store.order(sort: .recent) == [1, 2, 3, 4, 5, 6])
        #expect(try await store.order(sort: .oldest) == [6, 5, 4, 3, 2, 1])
        #expect(try await store.order(sort: .mostUsed) == [2, 5, 3, 1, 4, 6])
        #expect(try await store.order(sort: .alphabetical) == [2, 4, 6, 1, 3, 5])
    }

    // OC-4098. Red if Most Used counts copies (C's 5 copies would outrank P's 2 pastes).
    @Test("OC-4098 given item C copied 5 times and never pasted and item P pasted twice, when sort is Most Used, then P ranks above C")
    func repeatedCopiesDoNotCountAsUse() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let clock = rig.store.clock
        let c = try await rig.create(rig.text("key-c", "copied text"))
        clock.advance(ms: 1_000)
        let p = try await rig.create(rig.text("key-p", "pasted text"))
        for _ in 0..<4 {
            clock.advance(ms: 1_000)
            #expect(try await rig.ingest.ingest(rig.text("key-c", "copied text")).get().outcome == .bumped(c))
        }
        _ = try await rig.store.database.recordPaste(of: p).get()
        _ = try await rig.store.database.recordPaste(of: p).get()
        #expect(try await rig.store.database.content(of: c).get().copyCount == 5)

        let ranked = try await rig.store.database.listing(LibraryQuery(sort: .mostUsed)).ids

        #expect(ranked == [p, c])
        let counts = try await rig.store.rows(sort: .mostUsed).map(\.pasteCount)
        #expect(counts == [2, 0])
    }

    // MARK: Write failure (FR-014)

    // OC-4100. Red if a failed tag write is swallowed (no STO-DB-001), leaves a chip behind, or changes the tag count.
    @Test("OC-4100 given a failing write, when tag T is applied to an item, then STO-DB-001 with its message, the item has no chip and T's count is 0; once the fault clears the same call succeeds")
    func tagWriteFailureSurfacesAndChangesNothing() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, text: "xray"), Spec(n: 2, text: "yankee")])
        let tag = try await store.database.createTag(name: "T").get()
        try await store.install("CREATE TRIGGER inject_failure BEFORE INSERT ON itemTag BEGIN SELECT RAISE(ABORT, 'injected'); END")

        let failed = await store.database.toggleTag(id: tag, on: [Store.id(1)])

        #expect(errorCode(failed) == .stoDb001)
        #expect(message(.stoDb001) == "Flotsam couldn't save your history. Free up disk space and try again.")
        #expect(try store.count("itemTag") == 0)
        #expect(try await store.rows().allSatisfy { $0.tagNames.isEmpty })
        #expect(try await store.database.sidebarCounts().get().tags.map(\.count) == [0])
        #expect(try store.tagId("T") == tag)

        try await store.database.pool.write { try $0.execute(sql: "DROP TRIGGER inject_failure") }
        #expect(try await store.database.toggleTag(id: tag, on: [Store.id(1)]).get() == true)
        #expect(try await store.database.sidebarCounts().get().tags.map(\.count) == [1])
    }
}
