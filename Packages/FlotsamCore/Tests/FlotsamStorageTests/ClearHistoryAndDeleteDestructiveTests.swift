import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T batch 1, Clear History (FR-007-11) and delete(ids:) (FR-007-15). Expected values are literals from the
// oracle contract. Every destructive check asserts count delta, the identity of what went and the identity of what
// stayed, read through a second connection.

@Suite struct ClearHistoryDestructiveTests {
    private func fileBytes(_ s: Store, _ name: String) -> Data {
        (try? Data(contentsOf: s.root.appendingPathComponent(name))) ?? Data()
    }

    // MARK: Which items go

    /// OC-7089. Given 50 items of which 5 are exempt (three pinned, one trigger, one hotkey) and four tags, when Clear
    /// History runs over all time without the exempt option, then 45 go, the five exempt ones remain, and the four tags
    /// still exist.
    @Test func oc7089_clearAllTimeWithoutExemptKeepsExemptItemsAndTags() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        var specs = (1...50).map { Spec(n: $0, ageMs: Int64($0) * hourMs) }
        specs[0].pinned = true
        specs[1].pinned = true
        specs[2].trigger = ";keep"
        specs[3].hotkey = 9
        specs[4].pinned = true
        try await s.insert(specs)
        try await s.addTags(["red", "green", "blue", "gold"], onItem: 10)

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: false).get()

        #expect(outcome.deletedCount == 45)
        #expect(try s.presentIds() == [1, 2, 3, 4, 5])
        #expect(try s.count("tag") == 4)
        #expect(try s.trigger(of: 3) == ";keep")
    }

    /// OC-7090 / OC-7101. Given 50 items including pinned, trigger and hotkey ones, when Clear History runs with the
    /// exempt option, then all 50 go, and the deletion event lists the trigger and hotkey items so the registries drop
    /// them.
    @Test func oc7090_oc7101_clearWithExemptOptionDeletesEverythingAndPublishesIds() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        var specs = (1...50).map { Spec(n: $0, ageMs: Int64($0) * hourMs) }
        specs[0].pinned = true
        specs[1].trigger = ";gone"
        specs[2].hotkey = 4
        try await s.insert(specs)
        let events = EventCollector(s.database.events)

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: true).get()

        #expect(outcome.deletedCount == 50)
        #expect(try s.count("item") == 0)
        #expect(events.deletedIds == Set((1...50).map(Store.id)))
        #expect(events.deletedIds.contains(Store.id(2)) && events.deletedIds.contains(Store.id(3)))
    }

    /// OC-7091 with 0/1/max/max+1 boundaries. Given items 30 min, 59 min, 61 min, 23 h and 25 h old, when Clear History
    /// runs for "last hour", then exactly the first two go; for "last 24 hours", the first four go.
    @Test(arguments: [
        (ClearRange.lastHour, Set([3, 4, 5])),
        (ClearRange.last24Hours, Set([5])),
        (ClearRange.allTime, Set<Int>()),
    ])
    func oc7091_clearRangeWindows(range: ClearRange, expectedRemaining: Set<Int>) async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([
            Spec(n: 1, ageMs: 30 * 60_000),
            Spec(n: 2, ageMs: 59 * 60_000),
            Spec(n: 3, ageMs: 61 * 60_000),
            Spec(n: 4, ageMs: 23 * hourMs),
            Spec(n: 5, ageMs: 25 * hourMs),
        ])

        let outcome = try await s.database.clearHistory(range: range, includeExempt: false).get()

        #expect(try s.presentIds() == expectedRemaining)
        #expect(outcome.deletedCount == 5 - expectedRemaining.count)
    }

    /// OC-7092. Given item A created 5 days ago but copied again 10 min ago and item B created 10 min ago but last copied
    /// 5 days ago, when Clear History runs for "last hour", then A goes and B stays (the range is last-copied time).
    @Test func oc7092_rangeUsesLastCopiedNotCreated() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([
            Spec(n: 1, ageMs: 10 * 60_000, createdAgeMs: 5 * dayMs),
            Spec(n: 2, ageMs: 5 * dayMs, createdAgeMs: 10 * 60_000),
        ])

        let outcome = try await s.database.clearHistory(range: .lastHour, includeExempt: false).get()

        #expect(outcome.deletedCount == 1)
        #expect(try s.presentIds() == [2])
    }

    /// OC-7093 / OC-7094. Given 4 non-exempt items of 1,000 stored bytes and 1 pinned one, when the preview runs for all
    /// time, then it reports 4 items and 4,000 bytes and nothing is deleted; with the exempt option it reports 5.
    @Test func oc7093_oc7094_previewCountsWithoutDeleting() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        var specs = (1...5).map { Spec(n: $0, ageMs: hourMs, blobs: 1, repBytes: 1_000) }
        specs[4].pinned = true
        try await s.insert(specs)

        let plain = try await s.database.clearHistoryPreview(range: .allTime, includeExempt: false).get()
        let withExempt = try await s.database.clearHistoryPreview(range: .allTime, includeExempt: true).get()

        #expect(plain.count == 4)
        #expect(plain.bytes == 4_000)
        #expect(withExempt.count == 5)
        #expect(try s.count("item") == 5)
        #expect(s.exists(s.blobURL(1, 1)))
    }

    /// OC-7099 / OC-7100. Given an empty store, and given a store holding only exempt items, when the preview and Clear
    /// History run without the exempt option, then the preview is empty, nothing is deleted and no event is published.
    @Test func oc7099_oc7100_emptyOrOnlyExemptClearsNothing() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        let events = EventCollector(s.database.events)

        let emptyPreview = try await s.database.clearHistoryPreview(range: .allTime, includeExempt: false).get()
        let emptyOutcome = try await s.database.clearHistory(range: .allTime, includeExempt: false).get()
        try await s.insert([Spec(n: 1, ageMs: hourMs, pinned: true), Spec(n: 2, ageMs: hourMs, trigger: ";x")])
        let exemptOnlyPreview = try await s.database.clearHistoryPreview(range: .allTime, includeExempt: false).get()
        let exemptOnly = try await s.database.clearHistory(range: .allTime, includeExempt: false).get()

        #expect(emptyPreview.count == 0 && emptyOutcome.deletedCount == 0)
        #expect(exemptOnlyPreview.count == 0 && exemptOnly.deletedCount == 0)
        #expect(try s.presentIds() == [1, 2])
        #expect(events.deletedBatches.isEmpty)
    }

    /// Grace versus Clear History (brief). Given an item unpinned 1 h ago (inside the 24 h grace) and a pinned one, when
    /// Clear History runs without the exempt option, then the grace item goes (grace protects only sweep and budget) and
    /// the pinned one stays.
    @Test func graceDoesNotProtectFromClearHistory() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([
            Spec(n: 1, ageMs: 40 * dayMs, releasedAgoMs: hourMs),
            Spec(n: 2, ageMs: 40 * dayMs, pinned: true),
        ])

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: false).get()

        #expect(outcome.deletedCount == 1)
        #expect(try s.presentIds() == [2])
    }

    /// Race (brief), sequential approximation: the public API cannot interleave. Given a preview over four eligible
    /// items, when one is pinned, one gets a trigger and one a hotkey before Clear History runs, then those three survive
    /// and deletedCount is the actual number removed (1), not the preview's 4.
    @Test func race_itemsExemptedAfterPreviewSurviveClearHistory() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert((1...4).map { Spec(n: $0, ageMs: hourMs) })
        let preview = try await s.database.clearHistoryPreview(range: .allTime, includeExempt: false).get()
        _ = try await s.database.applyExemptionEdit(.setPinned(true), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setTrigger(";late"), to: Store.id(2)).get()
        _ = try await s.database.applyExemptionEdit(.setHotkey(Chord(keyCode: 5, modifiers: [])), to: Store.id(3)).get()

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: false).get()

        #expect(preview.count == 4)
        #expect(outcome.deletedCount == 1)
        #expect(try s.presentIds() == [1, 2, 3])
    }

    /// FR-007-11 batching. Given 1,200 items, when Clear History deletes them all, then no deletion event carries more
    /// than 500 ids, there are at least 3, and together they cover all 1,200.
    @Test func clearHistoryDeletesInBatchesOfAtMost500() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert((1...1_200).map { Spec(n: $0, ageMs: hourMs) })
        let events = EventCollector(s.database.events)

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: true).get()

        #expect(outcome.deletedCount == 1_200)
        #expect(try s.count("item") == 0)
        #expect(events.deletedBatches.count >= 3)
        #expect(events.deletedBatches.allSatisfy { $0.count <= 500 })
        #expect(events.deletedIds.count == 1_200)
    }

    // MARK: What must not be touched

    /// OC-7096 / OC-7097. Given a screenshot item whose original is a real file and a files item referencing a real file
    /// and a real folder, when Clear History runs with the exempt option, then both items go and the original, the files
    /// and the folder are untouched.
    @Test func oc7096_oc7097_originalsFilesAndFoldersSurviveClearHistory() async throws {
        let s = try await Store.make()
        let refs = References()
        defer { s.cleanUp(); refs.cleanUp() }
        let original = try refs.make("shot.png", "PNGDATA")
        let file = try refs.make("doc.txt", "DOC")
        let folder = refs.directory.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("INNER".utf8).write(to: folder.appendingPathComponent("inner.txt"))
        var shot = Spec(n: 1, kind: .screenshot, ageMs: hourMs, blobs: 1, repBytes: 10)
        shot.originalPath = original.path
        var files = Spec(n: 2, kind: .bundle, ageMs: hourMs)
        files.members = [(file.path, false), (folder.path, true)]
        try await s.insert([shot, files])

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: true).get()

        #expect(outcome.deletedCount == 2)
        #expect(try s.count("item") == 0)
        #expect(refs.read(original) == "PNGDATA")
        #expect(refs.read(file) == "DOC")
        #expect(refs.read(folder.appendingPathComponent("inner.txt")) == "INNER")
    }

    /// OC-7095. Given an item whose text contains a unique marker, with a blob and thumbnails, when Clear History runs over
    /// all time with the exempt option, then the marker is absent (UTF-8, lowercase and UTF-16) from flotsam.sqlite, its
    /// WAL and its shared-memory file, the blob and thumbnails are gone, and the checkpoint completed. The marker is first
    /// shown to be present, so the scan could have failed.
    @Test func oc7095_clearHistoryLeavesNoMarkerInDatabaseFiles() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        let marker = "ZEBRA-Marker-7095-Secret"
        try await s.insert([
            Spec(n: 1, ageMs: hourMs, blobs: 1, repBytes: 10, text: "before \(marker) after", thumbs: true),
            Spec(n: 2, ageMs: hourMs, pinned: true, text: "second \(marker)"),
        ])
        let variants = [Data(marker.utf8), Data(marker.lowercased().utf8), marker.data(using: .utf16LittleEndian)!]
        let everything = ["flotsam.sqlite", "flotsam.sqlite-wal", "flotsam.sqlite-shm"].reduce(into: Data()) { $0.append(fileBytes(s, $1)) }
        #expect(variants.contains { everything.range(of: $0) != nil })

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: true).get()

        #expect(outcome.deletedCount == 2)
        #expect(outcome.checkpointCompleted)
        for name in ["flotsam.sqlite", "flotsam.sqlite-wal", "flotsam.sqlite-shm"] {
            let bytes = fileBytes(s, name)
            #expect(variants.allSatisfy { bytes.range(of: $0) == nil }, "marker found in \(name)")
        }
        #expect(fileBytes(s, "flotsam.sqlite-wal").isEmpty)
        #expect(!s.exists(s.blobURL(1, 1)))
        #expect(!s.exists(s.thumbURL(1, 256)) && !s.exists(s.thumbURL(1, 512)))
    }

    /// OC-7087 (delete part). Given a files item with three real referenced files, when the user deletes it, then it goes
    /// and the three files are untouched.
    @Test func oc7087_deletingFilesItemLeavesReferencedFiles() async throws {
        let s = try await Store.make()
        let refs = References()
        defer { s.cleanUp(); refs.cleanUp() }
        let files = [try refs.make("a.txt", "A"), try refs.make("b.txt", "B"), try refs.make("c.txt", "C")]
        var item = Spec(n: 1, kind: .file, ageMs: hourMs, pinned: true)
        item.members = files.map { ($0.path, false) }
        try await s.insert([item, Spec(n: 2, ageMs: hourMs)])

        let removed = try await s.database.delete(ids: [Store.id(1)]).get()

        #expect(removed == [Store.id(1)])
        #expect(try s.presentIds() == [2])
        #expect(try s.count("bundleMember") == 0)
        #expect(files.map { refs.read($0) } == ["A", "B", "C"])
    }
}

@Suite struct ItemDeleteDestructiveTests {
    /// OC-7086. Given an item that is pinned, has a trigger and has a hotkey, when the user deletes it, then it is
    /// deleted unconditionally and the deletion event names it.
    @Test func oc7086_userDeleteIsUnconditional() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: hourMs, pinned: true, trigger: ";all", hotkey: 3), Spec(n: 2, ageMs: hourMs)])
        let events = EventCollector(s.database.events)

        let removed = try await s.database.delete(ids: [Store.id(1)]).get()

        #expect(removed == [Store.id(1)])
        #expect(try s.presentIds() == [2])
        #expect(events.deletedIds == [Store.id(1)])
    }

    /// OC-7122 / OC-7123 (happy part) / OC-7125. Given a bundle with a hotkey, a trigger, two blobs, two thumbnails, three
    /// real referenced files, and a screenshot item whose original is a real file, when both are deleted, then the event
    /// has arrived by the time delete returns, the rows, blobs and thumbnails are gone, and every referenced file and the
    /// original are untouched.
    @Test func oc7122_deleteCascadesRowsBlobsThumbsAndPublishesBeforeReturn() async throws {
        let s = try await Store.make()
        let refs = References()
        defer { s.cleanUp(); refs.cleanUp() }
        let files = [try refs.make("1.txt", "one"), try refs.make("2.txt", "two"), try refs.make("3.txt", "three")]
        let original = try refs.make("shot.png", "ORIGINAL")
        var bundle = Spec(n: 1, kind: .bundle, ageMs: hourMs, trigger: ";b", hotkey: 8, blobs: 2, repBytes: 10, thumbs: true)
        bundle.members = files.map { ($0.path, false) }
        var shot = Spec(n: 2, kind: .screenshot, ageMs: hourMs, blobs: 1, repBytes: 10)
        shot.originalPath = original.path
        try await s.insert([bundle, shot, Spec(n: 3, ageMs: hourMs, blobs: 1, repBytes: 10)])
        let events = EventCollector(s.database.events)

        let removed = try await s.database.delete(ids: [Store.id(1), Store.id(2)]).get()

        #expect(Set(removed) == [Store.id(1), Store.id(2)])
        #expect(events.deletedIds == [Store.id(1), Store.id(2)])
        #expect(try s.presentIds() == [3])
        #expect(try s.representationCount(1) == 0 && s.representationCount(2) == 0)
        #expect(try s.count("bundleMember") == 0)
        #expect(!s.exists(s.blobURL(1, 1)) && !s.exists(s.blobURL(1, 2)) && !s.exists(s.blobURL(2, 1)))
        #expect(!s.exists(s.thumbURL(1, 256)) && !s.exists(s.thumbURL(1, 512)))
        #expect(s.exists(s.blobURL(3, 1)))
        #expect(files.map { refs.read($0) } == ["one", "two", "three"])
        #expect(refs.read(original) == "ORIGINAL")
    }

    /// OC-7124 with empty, missing and duplicate boundaries. Given five items, when the user deletes ids 2, 3 and 5, then
    /// exactly 1 and 4 remain. An empty list deletes nothing; an id that does not exist is left out of the result; a
    /// duplicated id is removed once.
    @Test func oc7124_deleteRemovesExactlyTheGivenIds() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert((1...5).map { Spec(n: $0, ageMs: hourMs) })

        let none = try await s.database.delete(ids: []).get()
        #expect(none.isEmpty)
        #expect(try s.count("item") == 5)

        let missing = try await s.database.delete(ids: [Store.id(99)]).get()
        #expect(missing.isEmpty)
        #expect(try s.count("item") == 5)

        let removed = try await s.database.delete(ids: [Store.id(2), Store.id(3), Store.id(5), Store.id(3)]).get()

        #expect(Set(removed) == [Store.id(2), Store.id(3), Store.id(5)])
        #expect(try s.presentIds() == [1, 4])
    }

    /// OC-7026. Given a database that refuses to delete item rows, when the user deletes an item with two blobs, then the
    /// call fails with STO-DB-001, the item and both blobs remain, and no deletion event is published.
    @Test func oc7026_failedDeleteTransactionLeavesRowsBlobsAndEventsUntouched() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: hourMs, blobs: 2, repBytes: 10), Spec(n: 2, ageMs: hourMs)])
        try await s.database.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_delete BEFORE DELETE ON item BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        let events = EventCollector(s.database.events)

        let result = await s.database.delete(ids: [Store.id(1)])

        guard case .failure(let error) = result else {
            Issue.record("delete succeeded although the transaction was refused")
            return
        }
        #expect(error.code == .stoDb001)
        #expect(try s.presentIds() == [1, 2])
        #expect(s.exists(s.blobURL(1, 1)) && s.exists(s.blobURL(1, 2)))
        #expect(events.deletedBatches.isEmpty)
    }

    /// OC-7123. Given a blob file that cannot be removed, when the user deletes its item, then the delete still succeeds and
    /// the item is gone; the blob file remains as an orphan, and a later reconcile after the 10 minute grace removes it.
    @Test func oc7123_undeletableBlobDoesNotFailDeleteAndReconcileCleansItLater() async throws {
        var faulty = FaultyFileSystem()
        let stuck = Store.id(1).uuidString + ".1"
        faulty.failRemove = { $0.lastPathComponent == stuck }
        let s = try await Store.make(fileSystem: faulty)
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: hourMs, blobs: 1, repBytes: 10), Spec(n: 2, ageMs: hourMs, blobs: 1, repBytes: 10)])

        let removed = try await s.database.delete(ids: [Store.id(1)]).get()

        #expect(removed == [Store.id(1)])
        #expect(try s.presentIds() == [2])
        #expect(s.exists(s.blobURL(1, 1)))

        s.clock.advance(ms: 11 * 60_000)
        let healthy = try await Store.make(root: s.root, clock: s.clock)
        let outcome = try await healthy.database.reconcile().get()

        #expect(outcome.orphanBlobsRemoved == 1)
        #expect(!s.exists(s.blobURL(1, 1)))
        #expect(s.exists(s.blobURL(2, 1)))
    }
}
