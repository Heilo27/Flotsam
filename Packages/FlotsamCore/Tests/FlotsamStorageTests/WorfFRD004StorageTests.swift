import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// Worf's independent FRD-004 verification of the Storage organise and delete commands, written blind from the FRD and
// .claude/oracle/frd-004-contract.json. Each test names the OC it covers and the change that would turn it red. Expected
// values are literals; state is read back through a second read-only connection (Store.reader), never through the
// connection that wrote it. The builder's OrganizeStorageTests are not repeated here.

private let worfClassifiers = ItemClassifiers(
    editedText: { ItemClassification(kind: .text, contentKey: "edit:" + $0) },
    fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) })

private func code<T>(_ result: FlotsamResult<T>) -> ErrorCode? {
    if case .failure(let error) = result { return error.code }
    return nil
}

private extension Store {
    func scalar(_ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try reader().read { try Int.fetchOne($0, sql: sql, arguments: arguments) ?? -1 }
    }

    func tagCount() throws -> Int { try count("tag") }

    func strings(_ sql: String) throws -> [String] { try reader().read { try String.fetchAll($0, sql: sql) } }

    /// Item numbers (the trailing digits of the fixture id) in the order the public query returns them.
    func order(_ sort: LibrarySort, filter: LibraryFilter = .all) async throws -> [Int] {
        try await database.listing(LibraryQuery(filter: filter, sort: sort)).ids.map { Int(String($0.uuidString.suffix(12)))! }
    }

    func setPasteCount(_ n: Int, _ value: Int) async throws {
        try await database.pool.write {
            try $0.execute(sql: "UPDATE item SET pasteCount = ? WHERE id = ?", arguments: [value, Store.id(n).uuidString])
        }
    }

    func modified(_ url: URL) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }
}

@Suite struct WorfFRD004StorageTests {

    // MARK: Retention exemptions (FR-004-01, -03, -06)

    // OC-4006. Red if the sweep ignores `pinned`, or if it deletes by age without the unpinned guard.
    @Test("OC-4006 given an old pinned and an old unpinned item, when the sweep runs, then only the unpinned one goes")
    func sweepKeepsPinnedDropsUnpinned() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([
            Spec(n: 1, ageMs: 31 * dayMs, pinned: true), Spec(n: 2, ageMs: 31 * dayMs), Spec(n: 3, ageMs: dayMs),
        ])
        #expect(try store.count("item") == 3)

        let outcome = try await store.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        #expect(outcome.retentionDeleted == 1)
        #expect(try store.presentIds() == [1, 3])
        #expect(try store.count("item") == 2)
        let pinned = try await store.database.items(matching: LibraryQuery(filter: .pinned)).get()
        #expect(pinned.rows.map(\.id) == [Store.id(1)])
    }

    // OC-4037. Red if a tag link is treated as an exemption (an EXISTS(itemTag) clause in the sweep).
    @Test("OC-4037 given an old unpinned tagged item, when the sweep runs, then it goes and the tag itself stays")
    func sweepIgnoresTags() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 40 * dayMs), Spec(n: 2, ageMs: dayMs)])
        try await store.addTags(["Work"], onItem: 1)
        #expect(try store.tagCount() == 1)

        _ = try await store.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        #expect(try store.presentIds() == [2])
        #expect(try store.tagCount() == 1)
        #expect(try store.strings("SELECT name FROM tag") == ["Work"])
        #expect(try store.count("itemTag") == 0)
    }

    // OC-4046. Red if a note counts as an exemption.
    @Test("OC-4046 given an old unpinned item with a note, when the sweep runs, then it goes; a recent noted item stays")
    func sweepIgnoresNotes() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 40 * dayMs), Spec(n: 2, ageMs: dayMs)])
        _ = try await store.database.setNote("remember", for: Store.id(1)).get()
        _ = try await store.database.setNote("also", for: Store.id(2)).get()

        let outcome = try await store.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        #expect(outcome.retentionDeleted == 1)
        #expect(try store.presentIds() == [2])
        #expect(try store.strings("SELECT note FROM item") == ["also"])
    }

    // OC-4106 (+ hotkey half of FR-004-01's exemption list). Red if trigger or hotkey stop exempting.
    @Test("OC-4106 given old items with a trigger, with a hotkey and with neither, when the sweep runs, then only the bare one goes")
    func sweepKeepsTriggerAndHotkey() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([
            Spec(n: 1, ageMs: 40 * dayMs, trigger: ";sig"), Spec(n: 2, ageMs: 40 * dayMs, hotkey: 5), Spec(n: 3, ageMs: 40 * dayMs),
        ])

        let outcome = try await store.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        #expect(outcome.retentionDeleted == 1)
        #expect(try store.presentIds() == [1, 2])
        #expect(try store.trigger(of: 1) == ";sig")
    }

    // OC-4007. Red if image eviction picks pinned items or removes a pinned item's blob or thumbnails.
    @Test("OC-4007 given a pinned and two unpinned images over the budget, when the sweep runs, then only the unpinned are evicted")
    func budgetKeepsPinnedImage() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([
            Spec(n: 1, kind: .image, ageMs: 10 * dayMs, pinned: true, blobs: 1, repBytes: 300 * mib, thumbs: true),
            Spec(n: 2, kind: .image, ageMs: 9 * dayMs, blobs: 1, repBytes: 300 * mib, thumbs: true),
            Spec(n: 3, kind: .image, ageMs: 8 * dayMs, blobs: 1, repBytes: 300 * mib, thumbs: true),
        ])

        let outcome = try await store.database.runRetentionSweep(preset: .forever, budget: .mib500).get()

        #expect(outcome.budget.evictedCount == 2)
        #expect(try store.presentIds() == [1])
        #expect(store.exists(store.blobURL(1, 1)))
        #expect(store.exists(store.thumbURL(1, 256)) && store.exists(store.thumbURL(1, 512)))
        #expect(!store.exists(store.blobURL(2, 1)) && !store.exists(store.blobURL(3, 1)))
    }

    // MARK: Delete (FR-004-09)

    // OC-4066, OC-4067. Red if delete follows bundleMember.path or originalPath and removes the user's file.
    @Test("OC-4066 given a bundle and a screenshot that reference files on disk, when they are deleted, then the files are untouched")
    func deleteLeavesReferencedFiles() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("worf-refs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        var files: [URL] = []
        for name in ["a.txt", "b.txt", "c.txt"] { files.append(try store.makeReferencedFile(name, in: outside, contents: "data-" + name)) }
        let shot = try store.makeReferencedFile("shot.png", in: outside, contents: "png")
        for url in files + [shot] { try store.setModified(url, agoMs: 3 * dayMs) }
        let before = try (files + [shot]).map { try store.modified($0) }

        var bundle = Spec(n: 1, kind: .bundle)
        bundle.members = files.map { ($0.path, false) }
        try await store.insert([bundle, Spec(n: 2, kind: .screenshot, originalPath: shot.path), Spec(n: 3)])

        let removed = try await store.database.delete(ids: [Store.id(1), Store.id(2)]).get()

        #expect(Set(removed) == [Store.id(1), Store.id(2)])
        #expect(try store.presentIds() == [3])
        #expect(try store.count("bundleMember") == 0)
        for (url, date) in zip(files + [shot], before) {
            #expect(store.exists(url))
            #expect(try store.modified(url) == date)
        }
        #expect(store.contents(files[0]) == "data-a.txt")
    }

    // OC-4064. Red if delete removes the wrong ids, too many, or leaves the blob of a deleted item behind.
    @Test("OC-4064 given 5 items with 3 selected, when deleted, then count falls by 3, exactly those go, blobs follow and one event fires")
    func deleteThreeOfFive() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        var specs = (1...5).map { Spec(n: $0, ageMs: Int64($0) * hourMs, blobs: 1, repBytes: 10) }
        specs[2].thumbs = true
        try await store.insert(specs)
        try await store.addTags(["Keep"], onItem: 2)
        try await store.addTags(["Gone"], onItem: 3)
        let events = EventCollector(store.database.events)

        let removed = try await store.database.delete(ids: [Store.id(1), Store.id(3), Store.id(5)]).get()

        #expect(removed.count == 3)
        #expect(try store.count("item") == 2)
        #expect(try store.presentIds() == [2, 4])
        #expect(try store.count("representation") == 2)
        #expect(store.exists(store.blobURL(2, 1)) && store.exists(store.blobURL(4, 1)))
        #expect(!store.exists(store.blobURL(1, 1)) && !store.exists(store.blobURL(3, 1)) && !store.exists(store.blobURL(5, 1)))
        #expect(!store.exists(store.thumbURL(3, 256)))
        // tags are not items: both tags remain, only the link to the deleted item is gone
        #expect(try store.tagCount() == 2)
        #expect(try store.count("itemTag") == 1)
        #expect(events.deletedIds == [Store.id(1), Store.id(3), Store.id(5)])
        #expect(events.deletedBatches.count == 1)
    }

    // B6: empty and unknown inputs. Red if an empty delete touches rows or a stale id fails the whole action.
    @Test("OC-4071 given a one-item library, when deleted, then the library is empty; empty and unknown id lists change nothing")
    func deleteBoundaries() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([Spec(n: 1), Spec(n: 2)])

        #expect(try await store.database.delete(ids: []).get() == [])
        #expect(try store.presentIds() == [1, 2])
        let withStale = try await store.database.delete(ids: [Store.id(99), Store.id(1)]).get()
        #expect(withStale.contains(Store.id(1)))
        #expect(try store.presentIds() == [2])

        _ = try await store.database.delete(ids: [Store.id(2)]).get()
        #expect(try store.count("item") == 0)
        let page = try await store.database.items(matching: LibraryQuery()).get()
        #expect(page.totalCount == 0)
        #expect(page.rows.isEmpty)
    }

    // OC-4081, OC-4079. Red if ungroup removes member files or de-duplicates against an existing item.
    @Test("OC-4081 given a bundle whose members exist elsewhere as an item, when ungrouped, then files stay and both items exist")
    func ungroupKeepsFilesAndDoesNotDedupe() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("worf-ung-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        let f1 = try store.makeReferencedFile("f1.txt", in: outside, contents: "one")
        let f2 = try store.makeReferencedFile("f2.txt", in: outside, contents: "two")
        try store.setModified(f1, agoMs: 5 * dayMs)
        try store.setModified(f2, agoMs: 5 * dayMs)
        let before = [try store.modified(f1), try store.modified(f2)]

        var bundle = Spec(n: 1, kind: .bundle, ageMs: hourMs)
        bundle.members = [(f1.path, false), (f2.path, false)]
        var existing = Spec(n: 2, kind: .file, ageMs: 2 * hourMs)
        existing.text = nil
        try await store.insert([bundle, existing])
        try await store.database.pool.write {
            try $0.execute(sql: "UPDATE item SET contentKey = ? WHERE id = ?", arguments: ["file:" + f1.path, Store.id(2).uuidString])
        }

        let created = try await store.database.ungroup(bundle: Store.id(1), classifiers: worfClassifiers).get()

        #expect(created.count == 2)
        #expect(try store.count("item") == 3)
        #expect(try store.scalar("SELECT COUNT(*) FROM item WHERE contentKey = ?", ["file:" + f1.path]) == 2)
        #expect(try store.scalar("SELECT COUNT(*) FROM item WHERE id = ?", [Store.id(1).uuidString]) == 0)
        #expect(store.exists(f1) && store.exists(f2))
        #expect(try [store.modified(f1), store.modified(f2)] == before)
    }

    // MARK: Pin, sort and filters (FR-004-01, -12, -13)

    // OC-4005, OC-4001, OC-4002, OC-4008. Red if pinning changes lastCopiedAt or sort order puts pinned first.
    @Test("OC-4005 given 5 items, when the third is pinned, then the order is identical, Pinned lists exactly it and unpin restores counts")
    func pinDoesNotReorderAndCountsMove() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...5).map { Spec(n: $0, ageMs: Int64($0) * hourMs) })
        let pinnedBefore = try await store.database.sidebarCounts().get().pinned
        #expect(pinnedBefore == 0)
        let none = try await store.database.items(matching: LibraryQuery(filter: .pinned)).get()
        #expect(none.totalCount == 0 && none.rows.isEmpty)
        let before = try await store.order(.recent)
        #expect(before == [1, 2, 3, 4, 5])

        #expect(try await store.database.togglePinned(ids: [Store.id(3)]).get() == true)

        #expect(try await store.order(.recent) == [1, 2, 3, 4, 5])
        #expect(try await store.database.sidebarCounts().get().pinned == 1)
        #expect(try await store.order(.recent, filter: .pinned) == [3])

        // mixed selection pins both (OC-4001): pinned count rises by exactly 1 from 1 to 2, not by 2
        #expect(try await store.database.togglePinned(ids: [Store.id(3), Store.id(4)]).get() == true)
        #expect(try await store.database.sidebarCounts().get().pinned == 2)
        // all pinned selection unpins both (OC-4002): count falls by exactly 2
        #expect(try await store.database.togglePinned(ids: [Store.id(3), Store.id(4)]).get() == false)
        #expect(try await store.database.sidebarCounts().get().pinned == 0)
        #expect(try await store.order(.recent, filter: .pinned) == [])
        #expect(try await store.order(.recent) == [1, 2, 3, 4, 5])
    }

    // OC-4089, 4090, 4091, 4094. Red if any sort key is swapped, the tie-break is dropped, or pinned items float.
    @Test("OC-4089 given 6 items, when each sort applies, then the order is recent, oldest, most-used with ties by date, pinned in place")
    func sortOrders() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        // ages in hours: item n is n hours old, so Recent is 1,2,3,4,5,6
        try await store.insert((1...6).map { Spec(n: $0, ageMs: Int64($0) * hourMs, pinned: $0 == 4) })
        for (n, count) in [(1, 0), (2, 7), (3, 3), (4, 9), (5, 7), (6, 1)] { try await store.setPasteCount(n, count) }

        #expect(try await store.order(.recent) == [1, 2, 3, 4, 5, 6])
        #expect(try await store.order(.oldest) == [6, 5, 4, 3, 2, 1])
        // pasteCount desc: 4(9), then 2 and 5 tie at 7 and break by lastCopiedAt desc (2 is newer), 3(3), 6(1), 1(0)
        #expect(try await store.order(.mostUsed) == [4, 2, 5, 3, 6, 1])
    }

    // OC-4093, FR-004-12 alphabetical. Red if alphabetical falls back to byte order or ties are unstable between loads.
    @Test("OC-4093 given equal keys under every sort, when loaded three times, then the identity order never changes")
    func sortTiesAreStable() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        let sameInstant: Int64 = 2 * hourMs
        try await store.insert([
            Spec(n: 1, ageMs: sameInstant, text: "banana"), Spec(n: 2, ageMs: sameInstant, text: "Apple"),
            Spec(n: 3, ageMs: sameInstant, text: "cherry"), Spec(n: 4, ageMs: sameInstant, text: "Zed"),
            Spec(n: 5, ageMs: sameInstant, text: "same"), Spec(n: 6, ageMs: sameInstant, text: "same"),
        ])
        let expected: [LibrarySort: [Int]] = [
            .recent: [1, 2, 3, 4, 5, 6], .oldest: [1, 2, 3, 4, 5, 6], .mostUsed: [1, 2, 3, 4, 5, 6],
            // locale-aware: Apple, banana, cherry, same, same, Zed (a byte sort would put Zed before banana)
            .alphabetical: [2, 1, 3, 5, 6, 4],
        ]
        for sort in LibrarySort.allCases {
            for _ in 0..<3 { #expect(try await store.order(sort) == expected[sort]!, "sort \(sort)") }
        }
    }

    // MARK: Tags (FR-004-02, -04, -05)

    // OC-4010, 4011, 4015. Red if the length bound is off by one, or control characters are accepted.
    @Test("OC-4011 given the tag name boundary, when 32 chars, 33 chars, inner control chars and blanks are tried, then only 32 is accepted")
    func tagNameBoundary() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        let thirtyTwo = String(repeating: "a", count: 32)

        #expect(code(await store.database.createTag(name: thirtyTwo + "b")) == .orgVal001)
        #expect(try store.tagCount() == 0)
        #expect(code(await store.database.createTag(name: "bad\tname")) == .orgVal001)
        #expect(code(await store.database.createTag(name: "bad\nname")) == .orgVal001)
        #expect(code(await store.database.createTag(name: "   ")) == .orgVal001)
        #expect(code(await store.database.createTag(name: "")) == .orgVal001)
        #expect(try store.tagCount() == 0)

        _ = try await store.database.createTag(name: thirtyTwo).get()

        #expect(try store.tagCount() == 1)
        #expect(try store.strings("SELECT name FROM tag") == [thirtyTwo])
        let sidebar = try await store.database.sidebarCounts().get()
        #expect(sidebar.tags.map(\.name) == [thirtyTwo])
    }

    // OC-4020. Red if the ceiling is 99 or the 100th is refused.
    @Test("OC-4020 given exactly 99 tags, when one more is created, then it succeeds and the count is exactly 100")
    func hundredthTagAccepted() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        for n in 1...99 { _ = try await store.database.createTag(name: "tag \(n)").get() }
        #expect(try store.tagCount() == 99)

        _ = try await store.database.createTag(name: "tag 100").get()

        #expect(try store.tagCount() == 100)
        #expect(code(await store.database.createTag(name: "tag 101")) == .orgLim002)
        #expect(try store.tagCount() == 100)
    }

    // OC-4029, 4031, 4036, 4088. Red if deleteTag removes items, miscounts, or the Tag filter lists the wrong rows.
    @Test("OC-4029 given a tag on 5 of 8 items, when filtered and then deleted, then 5 rows list, 5 is reported, all 8 items stay")
    func tagFilterAndDelete() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...8).map { Spec(n: $0, ageMs: Int64($0) * hourMs) })
        let tag = try await store.database.createTagAndApply(name: "Five", to: (1...5).map(Store.id)).get()
        let empty = try await store.database.createTag(name: "Empty").get()

        let listed = try await store.database.items(matching: LibraryQuery(filter: .tag(tag))).get()
        #expect(listed.totalCount == 5)
        #expect(Set(listed.rows.map(\.id)) == Set((1...5).map(Store.id)))
        #expect(listed.rows.allSatisfy { $0.tagNames == ["Five"] })
        #expect(try await store.database.items(matching: LibraryQuery(filter: .tag(empty))).get().totalCount == 0)

        #expect(try await store.database.deleteTag(id: empty).get() == 0)
        #expect(try await store.database.deleteTag(id: tag).get() == 5)

        #expect(try store.count("item") == 8)
        #expect(try store.tagCount() == 0)
        #expect(try store.count("itemTag") == 0)
        #expect(try await store.database.items(matching: LibraryQuery()).get().rows.allSatisfy { $0.tagNames.isEmpty })
    }

    // MARK: Atomicity and performance (FR-004-14, NFR)

    // OC-4101. Red if tagging runs per item outside one transaction (the first 249 links would survive).
    @Test("OC-4101 given 500 items and a failure at the 250th link, when all are tagged, then none carries the tag and STO-DB-001 is returned")
    func tagging500IsAtomic() async throws {
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...500).map { Spec(n: $0) })
        let tag = try await store.database.createTag(name: "bulk").get()
        try await store.database.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER inject_failure BEFORE INSERT ON itemTag WHEN (SELECT COUNT(*) FROM itemTag) >= 249
                BEGIN SELECT RAISE(ABORT, 'injected'); END
                """)
        }

        let result = await store.database.toggleTag(id: tag, on: (1...500).map(Store.id))

        #expect(code(result) == .stoDb001)
        #expect(try store.count("itemTag") == 0)
        #expect(try store.count("item") == 500)
        #expect(try store.tagCount() == 1)
    }

    private func p95(_ samples: [Double]) -> Double { samples.sorted()[Int((Double(samples.count) * 0.95).rounded(.up)) - 1] }

    // OC-4102, OC-4103. Red if an organise command scans the library per item, or tagging 500 loops with a read each.
    @Test("OC-4102 given 10,000 items, when pin, tag and delete repeat, then p95 is under 100 ms and tagging 500 is under 1 s")
    func organisePerformance() async throws {
        // Every run asserts the work done; only the timing is best-of-three (TASK-447: wall-clock figures of a debug
        // build lost to scheduler stalls under a full-suite run). The bounds are unchanged: the metric is the worst
        // figure as a fraction of its own bound, so < 1 means p95 < 100 ms for each command and the bulk < 1000 ms.
        var figures = ""
        let worstFraction = try await bestOfThree(under: 1.0) {
            let store = try await Store.make()
            defer { store.cleanUp() }
            try await store.insert((1...10_000).map { Spec(n: $0, ageMs: Int64($0) * 1000) })
            #expect(try store.count("item") == 10_000)
            let tag = try await store.database.createTag(name: "perf").get()
            let clock = ContinuousClock()
            func millis(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

            var pin: [Double] = [], toggle: [Double] = [], delete: [Double] = []
            for n in 1...20 {
                pin.append(millis(await clock.measure { _ = await store.database.togglePinned(ids: [Store.id(n * 10)]) }))
                toggle.append(millis(await clock.measure { _ = await store.database.toggleTag(id: tag, on: [Store.id(n * 10 + 1)]) }))
                delete.append(millis(await clock.measure { _ = await store.database.delete(ids: [Store.id(n * 10 + 2)]) }))
            }
            let bulk = millis(await clock.measure { _ = await store.database.toggleTag(id: tag, on: (5_001...5_500).map(Store.id)) })

            // the work happened (a test of a no-op would pass any time budget)
            #expect(try store.scalar("SELECT COUNT(*) FROM item WHERE pinned = 1") == 20)
            #expect(try store.count("item") == 9_980)
            #expect(try store.scalar("SELECT COUNT(*) FROM itemTag") == 520)
            figures = "p95 pin \(p95(pin)) toggle \(p95(toggle)) delete \(p95(delete)) ms, bulk \(bulk) ms"
            return max(p95(pin) / 100, p95(toggle) / 100, p95(delete) / 100, bulk / 1000)
        }
        #expect(worstFraction < 1, "over budget on all 3 runs; last run: \(figures)")
    }
}
