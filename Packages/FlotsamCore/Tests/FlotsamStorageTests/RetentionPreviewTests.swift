import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T batch 2, the confirmation counts behind FR-007-09. A preview must report exactly what the matching sweep
// would delete, delete nothing itself, and be empty when the change cannot delete anything (longer retention, bigger
// budget). The sentence the user reads ("This permanently deletes k items older than 7 days...") is rendered above
// this layer; here the count and bytes it is built from are asserted. Expected values are literals.

@Suite struct RetentionPreviewTests {
    private let gib: Int64 = 1_073_741_824

    // MARK: Image budget

    /// OC-7061. 30 non-exempt images of 100 MiB under a 10 GiB budget. Lowering to 2 GiB would evict down to 90 % of
    /// the budget (1843.2 MiB), which is the 12 oldest. The preview says 12 before anything is deleted; confirming
    /// then removes those same 12 and keeps the 18 newest.
    /// Red if the preview deletes, miscounts, plans differently from enforcement, or evicts newest-first.
    @Test("OC-7061 lowering the budget to 2 GiB previews exactly the images it then deletes")
    func oc7061_budgetPreviewMatchesEviction() async throws {
        // given image n is n days old (so 30 is the oldest), 100 MiB each
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...30).map { Spec(n: $0, kind: .image, ageMs: Int64($0) * dayMs, blobs: 1, repBytes: 100 * mib) })
        #expect(try store.count("item") == 30)

        // when the 2 GiB budget is previewed
        let preview = try await store.database.imageBudgetEvictionPreview(.gib2).get()

        // then it reports 12 images and their 1200 MiB, and deletes nothing: rows and blob files are all still there
        #expect(preview == DeletionPreview(count: 12, bytes: 1_258_291_200))
        #expect(try store.count("item") == 30)
        #expect(try store.count("representation") == 30)
        #expect(store.exists(store.blobURL(30, 1)))

        // when the user confirms and the budget is enforced
        let outcome = try await store.database.enforceImageBudget(.gib2).get()

        // then exactly the previewed 12 oldest go (19...30) and the 18 newest stay
        #expect(outcome.evictedCount == 12)
        #expect(try store.count("item") == 18)
        #expect(try store.presentIds() == Set(1...18))
        #expect(!store.exists(store.blobURL(19, 1)))
        #expect(store.exists(store.blobURL(18, 1)))
    }

    /// OC-7061 boundary: at exactly the budget nothing is over, so no confirmation; one byte over does need one.
    @Test("OC-7061 boundary: exactly at 2 GiB previews nothing, one byte over previews two images")
    func oc7061_budgetBoundary() async throws {
        // given 16 images of 128 MiB: exactly 2 GiB
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...16).map { Spec(n: $0, kind: .image, ageMs: Int64($0) * dayMs, blobs: 1, repBytes: 128 * mib) })

        // then the 2 GiB preview is empty
        #expect(try await store.database.imageBudgetEvictionPreview(.gib2).get() == .none)

        // when one more 1-byte image arrives
        try await store.insert(Spec(n: 17, kind: .image, ageMs: 0, blobs: 1, repBytes: 1))

        // then the preview needs 2 evictions (2 GiB + 1 byte down to 1843.2 MiB removes two 128 MiB images)
        #expect(try await store.database.imageBudgetEvictionPreview(.gib2).get() == DeletionPreview(count: 2, bytes: 268_435_456))
        #expect(try store.count("item") == 17)
    }

    /// OC-7064. Raising the budget from 500 MiB to 10 GiB (or Unlimited) asks nothing and deletes nothing. The same
    /// library under 500 MiB does need eviction, so the empty answer is about the budget, not the data.
    @Test("OC-7064 raising the budget to 10 GiB previews nothing and deletes nothing")
    func oc7064_raiseBudget() async throws {
        // given 24 images of 25 MiB (600 MiB), more than a 500 MiB budget holds
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...24).map { Spec(n: $0, kind: .image, ageMs: Int64($0) * dayMs, blobs: 1, repBytes: 25 * mib) })

        // control: the current 500 MiB budget would remove 6 (600 down to 450 MiB)
        #expect(try await store.database.imageBudgetEvictionPreview(.mib500).get() == DeletionPreview(count: 6, bytes: 157_286_400))

        // when the budget is raised
        // then no confirmation is needed for 10 GiB or Unlimited
        #expect(try await store.database.imageBudgetEvictionPreview(.gib10).get() == .none)
        #expect(try await store.database.imageBudgetEvictionPreview(.unlimited).get() == .none)

        // and applying it deletes nothing
        let outcome = try await store.database.enforceImageBudget(.gib10).get()
        #expect(outcome.evictedCount == 0)
        #expect(try store.count("item") == 24)
        #expect(try store.presentIds() == Set(1...24))
    }

    // MARK: Retention period

    /// OC-7079. Retention Forever; 60 non-exempt items 8 to 67 days old, 5 items 1 to 5 days old, 4 old exempt items
    /// (2 pinned, 1 trigger, 1 shortcut). Shortening to 7 days previews exactly the 60, and the count is unchanged
    /// until the user confirms; the sweep then removes the same 60 and keeps the 9.
    /// Red if exempt items are counted, the recent ones are, the preview deletes, or preview and sweep disagree.
    @Test("OC-7079 shortening Forever to 7 days previews exactly the older non-exempt items")
    func oc7079_shortenPreview() async throws {
        // given the library above, 69 items
        let store = try await Store.make()
        defer { store.cleanUp() }
        var specs: [Spec] = (1...60).map { Spec(n: $0, ageMs: Int64(7 + $0) * dayMs, blobs: 1, repBytes: 1000) }
        specs += (61...65).map { Spec(n: $0, ageMs: Int64($0 - 60) * dayMs, blobs: 1, repBytes: 1000) }
        specs += [
            Spec(n: 66, ageMs: 300 * dayMs, pinned: true, blobs: 1, repBytes: 1000),
            Spec(n: 67, ageMs: 301 * dayMs, pinned: true, blobs: 1, repBytes: 1000),
            Spec(n: 68, ageMs: 302 * dayMs, trigger: ";old", blobs: 1, repBytes: 1000),
            Spec(n: 69, ageMs: 303 * dayMs, hotkey: 12, blobs: 1, repBytes: 1000),
        ]
        try await store.insert(specs)
        #expect(try store.count("item") == 69)

        // when Forever is previewed it is empty, and 7 days previews the 60 older non-exempt items
        #expect(try await store.database.retentionPreview(.forever).get() == .none)
        let preview = try await store.database.retentionPreview(.d7).get()
        #expect(preview == DeletionPreview(count: 60, bytes: 60_000))

        // then nothing was deleted while the confirmation was showing
        #expect(try store.count("item") == 69)
        #expect(store.exists(store.blobURL(1, 1)))

        // when the user confirms and the sweep runs under 7 days
        let outcome = try await store.database.runRetentionSweep(preset: .d7, budget: .unlimited).get()

        // then exactly those 60 are gone: the 5 recent and the 4 exempt remain
        #expect(outcome.retentionDeleted == 60)
        #expect(try store.count("item") == 9)
        #expect(try store.presentIds() == Set(61...69))
        #expect(!store.exists(store.blobURL(60, 1)))
        #expect(store.exists(store.blobURL(66, 1)))
    }

    /// OC-7079 boundary: older than the period means strictly older. Exactly 7 days is kept, one millisecond more goes.
    @Test("OC-7079 boundary: an item exactly 7 days old is not previewed, 7 days and 1 ms is")
    func oc7079_ageBoundary() async throws {
        // given items 7 days minus 1 ms, exactly 7 days, and 7 days plus 1 ms old
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([
            Spec(n: 1, ageMs: 7 * dayMs - 1),
            Spec(n: 2, ageMs: 7 * dayMs),
            Spec(n: 3, ageMs: 7 * dayMs + 1),
        ])

        // then only the oldest is counted
        #expect(try await store.database.retentionPreview(.d7).get().count == 1)
        let outcome = try await store.database.runRetentionSweep(preset: .d7, budget: .unlimited).get()
        #expect(outcome.retentionDeleted == 1)
        #expect(try store.presentIds() == [1, 2])
    }

    /// FR-007-10 through the preview: an exemption released an hour ago still protects the item (24 h grace), so
    /// the confirmation does not count it. Once 24 h pass it is counted.
    @Test("FR-007-09/10 a just-unpinned old item is not previewed until its grace ends")
    func previewHonoursGrace() async throws {
        // given an old item whose exemption was released 1 hour ago, and a plain old item
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert([
            Spec(n: 1, ageMs: 100 * dayMs, releasedAgoMs: hourMs),
            Spec(n: 2, ageMs: 100 * dayMs),
        ])

        // then only the plain one is counted
        #expect(try await store.database.retentionPreview(.d30).get().count == 1)

        // when 25 hours pass the released one is counted as well
        store.clock.advance(ms: 25 * hourMs)
        #expect(try await store.database.retentionPreview(.d30).get().count == 2)
    }

    /// OC-7082. Retention 30 days, nothing older than 7 days. Shortening to 7 days previews nothing (so the setting
    /// applies without asking) and deleting count is 0. A library that does hold an 8-day-old item previews 1, so the
    /// empty answer is about the data.
    @Test("OC-7082 shortening to 7 days with nothing that old previews nothing and deletes nothing")
    func oc7082_shortenNothingOld() async throws {
        // given 6 items 1 to 6 days old
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...6).map { Spec(n: $0, ageMs: Int64($0) * dayMs, blobs: 1, repBytes: 10) })

        // when 7 days is previewed and applied
        #expect(try await store.database.retentionPreview(.d7).get() == .none)
        let outcome = try await store.database.runRetentionSweep(preset: .d7, budget: .unlimited).get()

        // then nothing was deleted
        #expect(outcome.retentionDeleted == 0)
        #expect(try store.count("item") == 6)
        #expect(try store.presentIds() == Set(1...6))

        // control: with one 8-day-old item the same preview is 1
        try await store.insert(Spec(n: 7, ageMs: 8 * dayMs, blobs: 1, repBytes: 10))
        #expect(try await store.database.retentionPreview(.d7).get() == DeletionPreview(count: 1, bytes: 10))
    }

    /// OC-7083. Retention 7 days, items 1 to 6 days old. Lengthening to 30 days, 1 year or Forever previews nothing and
    /// each change plus a sweep deletes nothing.
    /// Red if any longer preset maps to a shorter period, or Forever is treated as a finite period.
    @Test("OC-7083 lengthening retention previews nothing and a sweep deletes nothing")
    func oc7083_lengthen() async throws {
        // given 6 items 1 to 6 days old
        let store = try await Store.make()
        defer { store.cleanUp() }
        try await store.insert((1...6).map { Spec(n: $0, ageMs: Int64($0) * dayMs, blobs: 1, repBytes: 10) })

        // when each longer preset is previewed and applied
        for preset in [RetentionPreset.d30, .d90, .y1, .forever] {
            // then no confirmation and no deletion, every time
            #expect(try await store.database.retentionPreview(preset).get() == .none, "preview for \(preset)")
            let outcome = try await store.database.runRetentionSweep(preset: preset, budget: .unlimited).get()
            #expect(outcome.retentionDeleted == 0, "sweep for \(preset)")
            #expect(try store.count("item") == 6, "count after \(preset)")
        }
        #expect(try store.presentIds() == Set(1...6))
    }
}
