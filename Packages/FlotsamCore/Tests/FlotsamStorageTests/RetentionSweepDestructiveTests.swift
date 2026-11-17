import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T batch 1, retention sweep and image budget (FR-007-08, 09, 10). Expected values are literals taken from the
// oracle contract. Every deletion is checked three ways: count delta, the identity of what went, and the identity of
// what stayed. State is read back through a second, read-only connection, never from the writer's own results alone.

@Suite struct RetentionSweepDestructiveTests {
    // MARK: Retention sweep: what ages out

    /// OC-7067. Given retention 30 d and four items last copied 31 d ago (plain, pinned, trigger, hotkey), when a sweep
    /// runs, then only the plain one goes and the other three keep their pin, trigger and hotkey.
    @Test func oc7067_sweepRemovesOnlyThePlainItemAndKeepsExemptOnes() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([
            Spec(n: 1, ageMs: 31 * dayMs),
            Spec(n: 2, ageMs: 31 * dayMs, pinned: true),
            Spec(n: 3, ageMs: 31 * dayMs, trigger: ";t31"),
            Spec(n: 4, ageMs: 31 * dayMs, hotkey: 12),
        ])

        let outcome = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        #expect(outcome.retentionDeleted == 1)
        #expect(try s.presentIds() == [2, 3, 4])
        #expect(try s.trigger(of: 3) == ";t31")
        #expect(try s.count("item") == 3)
    }

    /// OC-7068 plus the max+1 boundary. Given retention 30 d, an item at 29 d 23 h survives and one at 30 d 1 min goes.
    @Test func oc7068_sweepKeepsJustInsidePeriodAndRemovesJustOutside() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([
            Spec(n: 1, ageMs: 30 * dayMs - hourMs),
            Spec(n: 2, ageMs: 30 * dayMs + 60_000),
        ])

        let outcome = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        #expect(outcome.retentionDeleted == 1)
        #expect(try s.presentIds() == [1])
    }

    /// FR-007-09 per preset. Given items 6 d, 31 d, 91 d and 366 d old, when a sweep runs under each preset, then exactly
    /// the items inside that preset's period remain; Forever keeps all four.
    @Test(arguments: [
        (RetentionPreset.d7, Set([1])),
        (RetentionPreset.d30, Set([1])),
        (RetentionPreset.d90, Set([1, 2])),
        (RetentionPreset.y1, Set([1, 2, 3])),
        (RetentionPreset.forever, Set([1, 2, 3, 4])),
    ])
    func fr00709_sweepPresetPeriods(preset: RetentionPreset, expectedKept: Set<Int>) async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([
            Spec(n: 1, ageMs: 6 * dayMs),
            Spec(n: 2, ageMs: 31 * dayMs),
            Spec(n: 3, ageMs: 91 * dayMs),
            Spec(n: 4, ageMs: 366 * dayMs),
        ])

        let outcome = try await s.database.runRetentionSweep(preset: preset, budget: .unlimited).get()

        #expect(try s.presentIds() == expectedKept)
        #expect(outcome.retentionDeleted == 4 - expectedKept.count)
    }

    /// OC-7077 / OC-7078. Given nothing eligible, and given an empty store, when a sweep runs, then nothing is deleted,
    /// no deletion event is published and no error is returned.
    @Test func oc7077_oc7078_sweepWithNothingEligibleOrNothingStoredDoesNothing() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        let events = EventCollector(s.database.events)

        let emptyOutcome = try await s.database.runRetentionSweep(preset: .d7, budget: .mib500).get()
        #expect(emptyOutcome.retentionDeleted == 0)
        #expect(emptyOutcome.budget.evictedCount == 0)
        #expect(emptyOutcome.budget.notice == nil)

        try await s.insert([Spec(n: 1, ageMs: hourMs), Spec(n: 2, ageMs: 40 * dayMs, pinned: true)])
        let outcome = try await s.database.runRetentionSweep(preset: .d7, budget: .mib500).get()

        #expect(outcome.retentionDeleted == 0)
        #expect(try s.presentIds() == [1, 2])
        #expect(events.deletedBatches.isEmpty)
    }

    /// OC-7076 (functional part). Given 1,200 eligible items and 100 pinned ones, when a sweep runs, then exactly 1,200
    /// go in batches of at most 500 (so at least 3) and the 100 remain, and the sweep logs exactly one STO-POL-001
    /// "Retention sweep" line carrying count=1200. Red if the logged count is not the deleted total (a hard-coded 0, or
    /// the last batch size 200): no line with count=1200 appears. The line is read from this store's own recording
    /// sink, so no other test can supply or hide it.
    @Test func oc7076_sweepDeletesInBatchesOfAtMost500() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        var specs = (1...1_200).map { Spec(n: $0, ageMs: 31 * dayMs) }
        specs += (1_201...1_300).map { Spec(n: $0, ageMs: 31 * dayMs, pinned: true) }
        try await s.insert(specs)
        let events = EventCollector(s.database.events)

        let outcome = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        #expect(outcome.retentionDeleted == 1_200)
        #expect(try s.count("item") == 100)
        #expect(try s.presentIds() == Set(1_201...1_300))
        #expect(events.deletedBatches.count >= 3)
        #expect(events.deletedBatches.allSatisfy { $0.count <= 500 })
        #expect(events.deletedBatches.reduce(0) { $0 + $1.count } == 1_200)
        let lines = s.logs.lines(containing: ["STO-POL-001", "Retention sweep", "count=1200"])
        #expect(lines.count == 1)
    }

    // MARK: Exemption grace

    /// OC-7071. Given item Q 40 d old and pinned, unpinned at U, when sweeps run at U+1 h, U+23 h 59 min and
    /// U+24 h 1 min, then Q survives the first two and is gone after the third.
    @Test func oc7071_unpinnedItemSurvivesTwentyFourHoursThenGoes() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(Spec(n: 1, ageMs: 40 * dayMs, pinned: true))
        try await s.insert(Spec(n: 2, ageMs: 40 * dayMs))  // control: never exempt, gone on the first sweep
        #expect(try await s.database.applyExemptionEdit(.setPinned(false), to: Store.id(1)).get() == true)

        s.clock.advance(ms: hourMs)
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        #expect(try s.presentIds() == [1])

        s.clock.advance(ms: 22 * hourMs + 59 * 60_000)
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        #expect(try s.presentIds() == [1])

        s.clock.advance(ms: 2 * 60_000)
        let last = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        #expect(last.retentionDeleted == 1)
        #expect(try s.count("item") == 0)
    }

    /// OC-7072. Given Q unpinned at U, re-pinned at U+2 h and unpinned again at U+30 h, then exemptReleasedAt is null
    /// after the re-pin, the grace restarts at the second unpin, and Q is gone only after U+54 h.
    @Test func oc7072_repinClearsGraceAndSecondUnpinRestartsIt() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(Spec(n: 1, ageMs: 40 * dayMs, pinned: true))
        let unpinnedAt = s.clock.millis
        _ = try await s.database.applyExemptionEdit(.setPinned(false), to: Store.id(1)).get()
        #expect(try s.exemptReleasedAt(1) == unpinnedAt)

        s.clock.advance(ms: 2 * hourMs)
        _ = try await s.database.applyExemptionEdit(.setPinned(true), to: Store.id(1)).get()
        #expect(try s.exemptReleasedAt(1) == nil)

        s.clock.advance(ms: 28 * hourMs)
        _ = try await s.database.applyExemptionEdit(.setPinned(false), to: Store.id(1)).get()
        s.clock.advance(ms: 5 * 60_000)
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        #expect(try s.presentIds() == [1])

        s.clock.advance(ms: 23 * hourMs + 56 * 60_000)
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        #expect(try s.count("item") == 0)
    }

    /// OC-7073. Given R (trigger only) and S (hotkey only), both 40 d old, when the trigger and the hotkey are removed
    /// at V, then both carry exemptReleasedAt = V, survive a sweep at V+1 h, and go after V+24 h.
    @Test func oc7073_removingLastTriggerOrHotkeyStartsGrace() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: 40 * dayMs, trigger: ";r"), Spec(n: 2, ageMs: 40 * dayMs, hotkey: 7)])
        let v = s.clock.millis

        _ = try await s.database.applyExemptionEdit(.setTrigger(nil), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setHotkey(nil), to: Store.id(2)).get()

        let releasedR = try #require(try s.exemptReleasedAt(1))
        let releasedS = try #require(try s.exemptReleasedAt(2))
        #expect(abs(releasedR - v) <= 2_000)
        #expect(abs(releasedS - v) <= 2_000)

        s.clock.advance(ms: hourMs)
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        #expect(try s.presentIds() == [1, 2])

        s.clock.advance(ms: 23 * hourMs + 60_000)
        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()
        #expect(try s.count("item") == 0)
    }

    /// OC-7074. Given W pinned and with a trigger, when only the pin is removed, then exemptReleasedAt stays null and
    /// W survives a sweep 25 h later (an exemption remains).
    @Test func oc7074_removingOneOfTwoExemptionsKeepsItemProtected() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([Spec(n: 1, ageMs: 40 * dayMs, pinned: true, trigger: ";w"), Spec(n: 2, ageMs: 40 * dayMs)])

        _ = try await s.database.applyExemptionEdit(.setPinned(false), to: Store.id(1)).get()
        #expect(try s.exemptReleasedAt(1) == nil)

        s.clock.advance(ms: 25 * hourMs)
        let outcome = try await s.database.runRetentionSweep(preset: .d30, budget: .unlimited).get()

        #expect(outcome.retentionDeleted == 1)
        #expect(try s.presentIds() == [1])
    }

    // MARK: The race: exempt between selection and delete

    /// FR-007-09 / FR-007-10 race (no OC id: the contract has no interleaving case). Given three eligible items that
    /// were selected for deletion, when one is pinned, one gets a trigger and one gets a hotkey before the guarded
    /// delete runs, then none of those three is removed and the untouched control is. Uses the internal guarded-delete
    /// seam, so this test is tied to the implementation's name for it.
    @Test func race_itemExemptedAfterSelectionIsNotDeletedBySweepGuard() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert((1...4).map { Spec(n: $0, ageMs: 40 * dayMs) })
        let selected = (1...4).map(Store.id)
        _ = try await s.database.applyExemptionEdit(.setPinned(true), to: Store.id(1)).get()
        _ = try await s.database.applyExemptionEdit(.setTrigger(";late"), to: Store.id(2)).get()
        _ = try await s.database.applyExemptionEdit(.setHotkey(Chord(keyCode: 5, modifiers: [])), to: Store.id(3)).get()
        let events = EventCollector(s.database.events)

        let removed = try await s.database.deleteWhileEligible(
            ids: selected, guard: Exemption.autoDeletableGuard(now: s.clock.millis)).get()

        #expect(Set(removed) == [Store.id(4)])
        #expect(try s.presentIds() == [1, 2, 3])
        #expect(events.deletedIds == [Store.id(4)])
    }

    /// FR-007-10 race with grace. Given an item selected for deletion that was unpinned 1 h ago, when the guarded delete
    /// runs, then it survives; given the same item unpinned 25 h ago, it goes.
    @Test func race_graceBoundaryAtGuardedDelete() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert([
            Spec(n: 1, ageMs: 40 * dayMs, releasedAgoMs: hourMs),
            Spec(n: 2, ageMs: 40 * dayMs, releasedAgoMs: 25 * hourMs),
        ])

        let removed = try await s.database.deleteWhileEligible(
            ids: [Store.id(1), Store.id(2)], guard: Exemption.autoDeletableGuard(now: s.clock.millis)).get()

        #expect(Set(removed) == [Store.id(2)])
        #expect(try s.presentIds() == [1])
    }

    // MARK: Image budget

    private func images(_ range: ClosedRange<Int>, mibEach: Int64 = 100, oldestFirst: Bool = true, extra: (Int) -> Spec = { Spec(n: $0) }) -> [Spec] {
        range.map { n in
            var spec = extra(n)
            spec.n = n
            spec.kind = .image
            spec.blobs = 1
            spec.repBytes = mibEach * mib
            spec.ageMs = Int64(oldestFirst ? (range.upperBound - n + 1) : n) * dayMs
            return spec
        }
    }

    /// OC-7054. Given budget 500 MiB and six unpinned 100 MiB images with distinct ages, when the budget is enforced,
    /// then the total ends at or under 450 MiB, the two oldest are gone with their blobs, and no newer one is removed.
    @Test func oc7054_budgetEvictsOldestPrefixDownToNinetyPercent() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(images(1...6))  // n = 1 is the oldest

        let outcome = try await s.database.enforceImageBudget(.mib500).get()

        #expect(outcome.evictedCount == 2)
        #expect(try s.presentIds() == [3, 4, 5, 6])
        #expect(try s.sumRepresentationBytes() == 400 * mib)
        #expect(!s.exists(s.blobURL(1, 1)))
        #expect(!s.exists(s.blobURL(2, 1)))
        #expect(s.exists(s.blobURL(3, 1)))
        #expect(outcome.notice == nil)
    }

    /// OC-7055. Given 495 MiB of images plus a just-ingested 20 MiB image that is also the oldest, when the budget is
    /// enforced protecting it, then it survives and older non-exempt images are removed instead.
    @Test func oc7055_justIngestedImageIsNeverEvicted() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        var specs = images(2...6, mibEach: 99)  // 495 MiB, ages 5 d..1 d
        var fresh = Spec(n: 1, kind: .image, ageMs: 400 * dayMs)  // oldest by date, so eviction would choose it first
        fresh.blobs = 1
        fresh.repBytes = 20 * mib
        specs.append(fresh)
        try await s.insert(specs)

        let outcome = try await s.database.enforceImageBudget(.mib500, protecting: Store.id(1)).get()

        #expect(try s.presentIds().contains(1))
        // 495 + 20 = 515 MiB against a 450 MiB target: the oldest unprotected image (99 MiB) takes it to 416 MiB, so exactly one goes.
        #expect(outcome.evictedCount == 1)
        #expect(try s.presentIds() == [1, 3, 4, 5, 6])
        #expect(try s.sumRepresentationBytes() == 416 * mib)
        #expect(s.exists(s.blobURL(1, 1)))
    }

    /// OC-7056 / OC-7087 (budget part). Given 400 MiB of images, 300 MiB of text-kind blobs, 2 GiB of file-kind data and
    /// a files item with three real referenced files, when a 10 MiB image arrives and the budget is enforced, then
    /// nothing is deleted and the referenced files are untouched.
    @Test func oc7056_onlyImagesCountTowardBudget() async throws {
        let s = try await Store.make()
        let refs = References()
        defer { s.cleanUp(); refs.cleanUp() }
        let files = [try refs.make("a.txt", "A"), try refs.make("b.txt", "B"), try refs.make("c.txt", "C")]
        var specs = images(1...4)  // 400 MiB
        var text = Spec(n: 5, kind: .text, ageMs: 50 * dayMs)
        text.blobs = 1
        text.repBytes = 300 * mib
        var file = Spec(n: 6, kind: .file, ageMs: 50 * dayMs)
        file.blobs = 1
        file.repBytes = 2 * 1024 * mib
        file.members = files.map { ($0.path, false) }
        var newest = Spec(n: 7, kind: .image, ageMs: 0)
        newest.blobs = 1
        newest.repBytes = 10 * mib
        specs += [text, file, newest]
        try await s.insert(specs)

        let outcome = try await s.database.enforceImageBudget(.mib500, protecting: Store.id(7)).get()

        #expect(outcome.evictedCount == 0)
        #expect(try s.count("item") == 7)
        #expect(outcome.notice == nil)
        #expect(refs.read(files[0]) == "A" && refs.read(files[1]) == "B" && refs.read(files[2]) == "C")
    }

    /// OC-7057 / OC-7058. Given 600 MiB of pinned images only, when the budget check runs, then nothing is deleted and one
    /// STO-LIM-001 is returned; a second check 1 h later returns none; a check after 24 h 1 min returns another.
    @Test func oc7057_oc7058_pinnedOnlyOverBudgetNoticesOncePerDay() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(images(1...6, extra: { Spec(n: $0, pinned: true) }))

        let first = try await s.database.enforceImageBudget(.mib500).get()
        #expect(first.evictedCount == 0)
        #expect(first.notice?.code == .stoLim001)

        s.clock.advance(ms: hourMs)
        let second = try await s.database.enforceImageBudget(.mib500).get()
        #expect(second.evictedCount == 0)
        #expect(second.notice == nil)

        s.clock.advance(ms: 24 * hourMs + 60_000 - hourMs)  // now T + 24 h + 1 min
        let third = try await s.database.enforceImageBudget(.mib500).get()
        #expect(third.evictedCount == 0)
        #expect(third.notice?.code == .stoLim001)
        #expect(try s.count("item") == 6)
    }

    /// OC-7058, boundary. Given 600 MiB of pinned images only and a first STO-LIM-001 Notice at T, when the budget is
    /// checked 24 h minus 1 ms later, then no Notice; when checked exactly 24 h after T, then the Notice is due again; and
    /// immediately after that one, none. Red if the throttle suppresses at exactly 24 h (`<=` instead of `<`): the check
    /// at T + 24 h returns no Notice.
    @Test func oc7058_noticeThrottleBoundaryIsExactlyTwentyFourHours() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(images(1...6, extra: { Spec(n: $0, pinned: true) }))

        let first = try await s.database.enforceImageBudget(.mib500).get()
        s.clock.advance(ms: 24 * hourMs - 1)
        let justBefore = try await s.database.enforceImageBudget(.mib500).get()
        s.clock.advance(ms: 1)
        let atBoundary = try await s.database.enforceImageBudget(.mib500).get()
        let rightAfter = try await s.database.enforceImageBudget(.mib500).get()

        #expect(first.notice?.code == .stoLim001)
        #expect(justBefore.notice == nil)
        #expect(atBoundary.notice?.code == .stoLim001)
        #expect(rightAfter.notice == nil)
        #expect(first.evictedCount == 0 && justBefore.evictedCount == 0 && atBoundary.evictedCount == 0)
        #expect(try s.count("item") == 6)
    }

    /// OC-7054 / OC-7066, boundary. Given five unpinned 100 MiB images (exactly 500 MiB, the budget), when the budget is
    /// enforced, then nothing is evicted, all five stay with their blobs and no Notice is raised; given the same five with
    /// one extra byte on the newest (500 MiB + 1 B), then only the oldest goes (500 MiB + 1 B minus 100 MiB is already under the
    /// 450 MiB target) and the other four stay. At the limit is within budget; one byte over is not.
    @Test func oc7054_oc7066_totalExactlyAtBudgetEvictsNothingOneByteOverEvicts() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(images(1...5))

        let atLimit = try await s.database.enforceImageBudget(.mib500).get()

        #expect(try s.sumRepresentationBytes() == 500 * mib)
        #expect(atLimit.evictedCount == 0)
        #expect(atLimit.notice == nil)
        #expect(try s.presentIds() == [1, 2, 3, 4, 5])
        #expect((1...5).allSatisfy { s.exists(s.blobURL($0, 1)) })

        try await s.database.pool.write { db in
            try db.execute(sql: "UPDATE representation SET byteSize = byteSize + 1 WHERE itemId = ?", arguments: [Store.id(5).uuidString])
        }
        let overByOne = try await s.database.enforceImageBudget(.mib500).get()

        #expect(overByOne.evictedCount == 1)
        #expect(try s.presentIds() == [2, 3, 4, 5])
        #expect(!s.exists(s.blobURL(1, 1)))
        #expect((2...5).allSatisfy { s.exists(s.blobURL($0, 1)) })
        #expect(overByOne.notice == nil)
    }

    /// OC-7059. Given 450 MiB of pinned, triggered and hotkeyed images plus 200 MiB of non-exempt images, when the
    /// budget is enforced, then every non-exempt image goes, every exempt one stays and no notice is raised.
    @Test func oc7059_budgetTakesAllNonExemptAndSparesExemptWithoutNotice() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        var specs = images(1...3, mibEach: 150) { n in
            switch n {
            case 1: Spec(n: n, pinned: true)
            case 2: Spec(n: n, trigger: ";img")
            default: Spec(n: n, hotkey: 3)
            }
        }
        specs += images(4...5, mibEach: 100).map { $0 }
        try await s.insert(specs)

        let outcome = try await s.database.enforceImageBudget(.mib500).get()

        #expect(outcome.evictedCount == 2)
        #expect(try s.presentIds() == [1, 2, 3])
        #expect(outcome.notice == nil)
    }

    /// Grace versus budget (brief). Given the oldest image was unpinned 1 h ago and five newer 100 MiB images are
    /// non-exempt, when the budget is enforced, then the grace image survives and the next two oldest go instead.
    @Test func graceProtectsOldestImageFromBudget() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(images(1...6, extra: { $0 == 1 ? Spec(n: $0, releasedAgoMs: hourMs) : Spec(n: $0) }))

        let outcome = try await s.database.enforceImageBudget(.mib500).get()

        #expect(outcome.evictedCount == 2)
        #expect(try s.presentIds() == [1, 4, 5, 6])
    }

    /// OC-7060. Given budget Unlimited, 20 GiB of unpinned images and retention Forever, when a sweep runs, then nothing
    /// is deleted.
    @Test func oc7060_unlimitedBudgetAndForeverDeleteNothing() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(images(1...4, mibEach: 5 * 1024))

        let outcome = try await s.database.runRetentionSweep(preset: .forever, budget: .unlimited).get()

        #expect(outcome.retentionDeleted == 0)
        #expect(outcome.budget.evictedCount == 0)
        #expect(try s.count("item") == 4)
    }

    /// OC-7066. Given budget 500 MiB and no image items (only text), when the budget is enforced, then nothing goes and
    /// no notice is returned.
    @Test func oc7066_noImagesMeansNoEvictionAndNoNotice() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        let empty = try await s.database.enforceImageBudget(.mib500).get()
        try await s.insert([Spec(n: 1, ageMs: dayMs), Spec(n: 2, ageMs: dayMs)])

        let withText = try await s.database.enforceImageBudget(.mib500).get()

        #expect(empty.evictedCount == 0 && empty.notice == nil)
        #expect(withText.evictedCount == 0 && withText.notice == nil)
        #expect(try s.count("item") == 2)
    }

    /// Budget boundary 0/1/max/max+1. Given images summing exactly to the limit, nothing is evicted; one byte over
    /// evicts down to 90 %.
    @Test func budgetBoundaryExactlyAtLimitDoesNotEvict() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(images(1...5))  // exactly 500 MiB

        let atLimit = try await s.database.enforceImageBudget(.mib500).get()
        #expect(atLimit.evictedCount == 0)
        #expect(try s.count("item") == 5)

        try await s.insert(Spec(n: 6, kind: .image, ageMs: 0, blobs: 1, repBytes: 1))
        let over = try await s.database.enforceImageBudget(.mib500).get()
        #expect(over.evictedCount == 1)  // 500 MiB + 1 byte, down to 450 MiB: one 100 MiB image is enough
        #expect(try s.presentIds() == [2, 3, 4, 5, 6])
    }

    /// Budget race (brief): an image pinned after selection is not evicted. Given an oldest image that is pinned just
    /// before the guarded delete runs, then it survives and the unguarded control goes.
    @Test func race_imagePinnedAfterSelectionSurvivesBudgetGuard() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert(images(1...3))
        _ = try await s.database.applyExemptionEdit(.setPinned(true), to: Store.id(1)).get()

        let removed = try await s.database.deleteWhileEligible(
            ids: [Store.id(1), Store.id(2)], guard: Exemption.autoDeletableGuard(now: s.clock.millis)).get()

        #expect(Set(removed) == [Store.id(2)])
        #expect(try s.presentIds() == [1, 3])
        #expect(s.exists(s.blobURL(1, 1)))
        #expect(!s.exists(s.blobURL(2, 1)))
    }

    /// OC-7084. Given retention Forever, budget 500 MiB and 600 MiB of unpinned images up to 3 years old, when a sweep
    /// runs, then no item goes for age and the oldest images are evicted down to 450 MiB or less.
    @Test func oc7084_foreverRetentionStillEnforcesBudget() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        var specs = images(1...6)
        for i in specs.indices { specs[i].ageMs = Int64(7 - specs[i].n) * 365 * dayMs / 2 }  // 3 y ... 0.5 y
        try await s.insert(specs)

        let outcome = try await s.database.runRetentionSweep(preset: .forever, budget: .mib500).get()

        #expect(outcome.retentionDeleted == 0)
        #expect(outcome.budget.evictedCount == 2)
        #expect(try s.presentIds() == [3, 4, 5, 6])
        #expect(try s.sumRepresentationBytes() == 400 * mib)
    }

    /// OC-7087 (sweep and budget). Given a pinned files item 40 d old referencing three real files, when a sweep, a
    /// budget pass and a non-exempt Clear History run, then the item and the files remain, unchanged.
    @Test func oc7087_pinnedFilesItemAndItsFilesSurviveSweepBudgetAndClear() async throws {
        let s = try await Store.make()
        let refs = References()
        defer { s.cleanUp(); refs.cleanUp() }
        let files = [try refs.make("one.txt", "1"), try refs.make("two.txt", "22"), try refs.make("three.txt", "333")]
        var item = Spec(n: 1, kind: .file, ageMs: 40 * dayMs, pinned: true)
        item.members = files.map { ($0.path, false) }
        try await s.insert(item)

        _ = try await s.database.runRetentionSweep(preset: .d30, budget: .mib500).get()
        _ = try await s.database.enforceImageBudget(.mib500).get()
        let cleared = try await s.database.clearHistory(range: .allTime, includeExempt: false).get()

        #expect(cleared.deletedCount == 0)
        #expect(try s.presentIds() == [1])
        #expect(try s.count("bundleMember") == 3)
        #expect(files.map { refs.read($0) } == ["1", "22", "333"])
    }
}
