import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-008 contract tests, oracle OC-8047...OC-8056: what the Storage pane's confirmations promise against the real
// database. The pane (alert, popup, Cancel button) is App-target UI with no package seam; the preview is the number the
// alert prints, "Cancel" is "the enforcing call is never made", and "Confirm" is the enforcing call. Expected values are
// literals derived by hand from the oracle's scenario, never from the production planner.

@Suite struct Frd008ContractStorageTests {
    /// Ten unpinned 100 MiB images I1...I10 (n 1...10, I1 oldest), a pinned image P (n 11) and a shortcut image S (n 12).
    private func imageLibrary(_ store: Store) async throws {
        var specs: [Spec] = (1...10).map { Spec(n: $0, kind: .image, ageMs: Int64(12 - $0) * dayMs, blobs: 1, repBytes: 100 * mib) }
        specs.append(Spec(n: 11, kind: .image, ageMs: 20 * dayMs, pinned: true, blobs: 1, repBytes: 100 * mib))
        specs.append(Spec(n: 12, kind: .image, ageMs: 30 * dayMs, hotkey: 7, blobs: 1, repBytes: 100 * mib))
        try await store.insert(specs)
    }

    /// OC-8047. 1200 MiB of images under 2 GB; choosing 500 MB would evict down to 450 MiB: the 8 oldest unpinned
    /// (I1...I8, 800 MiB). Cancel is the absence of the enforcing call, so the library is unchanged after the preview.
    /// Red if the preview deletes, counts the exempt P/S, or reports a different N/Z than the alert prints.
    @Test func oc8047_cancelAfterBudgetPreviewDeletesNothing() async throws {
        // given the library above
        let store = try await Store.make(); defer { store.cleanUp() }
        try await imageLibrary(store)
        #expect(try store.count("item") == 12)

        // when 500 MB is previewed (the alert's N and Z) and the user cancels
        let preview = try await store.database.imageBudgetEvictionPreview(.mib500).get()

        // then N is 8 and Z is 800 MiB, and nothing was deleted: I1...I10, P and S are all present
        #expect(preview == DeletionPreview(count: 8, bytes: 838_860_800))
        #expect(try store.count("item") == 12)
        #expect(try store.presentIds() == Set(1...12))
        #expect(store.exists(store.blobURL(1, 1)))
    }

    /// OC-8048. Confirming removes exactly N = 8, the 8 oldest unpinned, and keeps P and S.
    /// Red if pinned/shortcut images are evicted, the wrong images go, or the count differs from the preview.
    @Test func oc8048_confirmRemovesTheNOldestUnpinned() async throws {
        // given the OC-8047 library
        let store = try await Store.make(); defer { store.cleanUp() }
        try await imageLibrary(store)

        // when the user confirms 500 MB
        let outcome = try await store.database.enforceImageBudget(.mib500).get()

        // then image count drops by exactly 8, I1...I8 are gone, I9, I10, P and S remain
        #expect(outcome.evictedCount == 8)
        #expect(try store.count("item") == 4)
        #expect(try store.presentIds() == [9, 10, 11, 12])
        #expect(!store.exists(store.blobURL(1, 1)))
        #expect(!store.exists(store.blobURL(8, 1)))
        #expect(store.exists(store.blobURL(9, 1)))
        #expect(store.exists(store.blobURL(11, 1)))
        #expect(store.exists(store.blobURL(12, 1)))
    }

    /// OC-8049. Total image size well under 500 MB: the preview is empty (no confirmation) and applying deletes nothing.
    @Test func oc8049_underBudgetNeedsNoConfirmation() async throws {
        // given 3 images of 10 MiB
        let store = try await Store.make(); defer { store.cleanUp() }
        try await store.insert((1...3).map { Spec(n: $0, kind: .image, ageMs: Int64($0) * dayMs, blobs: 1, repBytes: 10 * mib) })

        // then the preview is empty, and applying 500 MB deletes nothing
        #expect(try await store.database.imageBudgetEvictionPreview(.mib500).get() == .none)
        #expect(try await store.database.enforceImageBudget(.mib500).get().evictedCount == 0)
        #expect(try store.count("item") == 3)
        #expect(try store.presentIds() == [1, 2, 3])
    }

    /// OC-8050. Raising to 10 GB: no preview, nothing deleted, even though the library is over the old 500 MB budget.
    @Test func oc8050_raisingTheBudgetDeletesNothing() async throws {
        // given 12 images of 100 MiB, over a 500 MB budget
        let store = try await Store.make(); defer { store.cleanUp() }
        try await store.insert((1...12).map { Spec(n: $0, kind: .image, ageMs: Int64($0) * dayMs, blobs: 1, repBytes: 100 * mib) })
        #expect(try await store.database.imageBudgetEvictionPreview(.mib500).get().count > 0, "control: the data is over 500 MB")

        // then 10 GB previews nothing and applying it deletes nothing
        #expect(try await store.database.imageBudgetEvictionPreview(.gib10).get() == .none)
        #expect(try await store.database.enforceImageBudget(.gib10).get().evictedCount == 0)
        #expect(try store.count("item") == 12)
    }

    /// OC-8051 / OC-8052. K = 4 unpinned items and pinned Q, all last copied 10 days ago, retention 90 days. Choosing 7
    /// days previews 4 (Q exempt); Cancel leaves everything; Confirm removes exactly the 4 and keeps Q.
    /// Red if Q is counted or deleted, the preview differs from the sweep, or the preview itself deletes.
    @Test func oc8051_oc8052_shortenCancelThenConfirm() async throws {
        // given K1...K4 (n 1...4) and Q (n 5), all 10 days old
        let store = try await Store.make(); defer { store.cleanUp() }
        var specs = (1...4).map { Spec(n: $0, ageMs: 10 * dayMs, blobs: 1, repBytes: 1000) }
        specs.append(Spec(n: 5, ageMs: 10 * dayMs, pinned: true, blobs: 1, repBytes: 1000))
        try await store.insert(specs)

        // when 7 days is previewed and the user cancels (no sweep call)
        #expect(try await store.database.retentionPreview(.d7).get() == DeletionPreview(count: 4, bytes: 4000))

        // then nothing is deleted: count delta 0, all K items and Q present
        #expect(try store.count("item") == 5)
        #expect(try store.presentIds() == Set(1...5))

        // when the user confirms
        let outcome = try await store.database.runRetentionSweep(preset: .d7, budget: .unlimited).get()

        // then the count drops by exactly 4, K1...K4 are absent and Q is present
        #expect(outcome.retentionDeleted == 4)
        #expect(try store.count("item") == 1)
        #expect(try store.presentIds() == [5])
        #expect(!store.exists(store.blobURL(1, 1)))
        #expect(store.exists(store.blobURL(5, 1)))
    }

    /// OC-8053. Retention 7 days, items 1 to 3 days old; choosing 90 days asks nothing and deletes nothing.
    @Test func oc8053_lengtheningRetentionDeletesNothing() async throws {
        // given 3 recent items and 2 that 7 days would remove (40 and 80 days old, inside 90 days): the longer period
        // must not touch either
        let store = try await Store.make(); defer { store.cleanUp() }
        try await store.insert((1...3).map { Spec(n: $0, ageMs: Int64($0) * dayMs, blobs: 1, repBytes: 10) })
        try await store.insert([Spec(n: 4, ageMs: 40 * dayMs), Spec(n: 5, ageMs: 80 * dayMs)])

        // then 90 days previews nothing, and applying it deletes nothing
        #expect(try await store.database.retentionPreview(.d90).get() == .none)
        #expect(try await store.database.runRetentionSweep(preset: .d90, budget: .unlimited).get().retentionDeleted == 0)
        #expect(try store.count("item") == 5)
        #expect(try store.presentIds() == Set(1...5))
    }

    /// OC-8054 (data half). No item copied in the last hour: the Last hour preview is empty, which is what disables
    /// Delete. The control proves the empty answer is about the range: one item copied 30 minutes ago makes it 1.
    @Test func oc8054_lastHourPreviewIsEmptyWhenNothingIsThatRecent() async throws {
        // given items copied 2 hours and 3 days ago
        let store = try await Store.make(); defer { store.cleanUp() }
        try await store.insert([Spec(n: 1, ageMs: 2 * hourMs), Spec(n: 2, ageMs: 3 * dayMs)])

        // then Last hour previews nothing, and a Delete (if it ran) would remove nothing
        #expect(try await store.database.clearHistoryPreview(range: .lastHour, includeExempt: false).get() == .none)
        #expect(try await store.database.clearHistory(range: .lastHour, includeExempt: false).get().deletedCount == 0)
        #expect(try store.presentIds() == [1, 2])

        // control: an item copied 30 minutes ago is counted
        try await store.insert(Spec(n: 3, ageMs: hourMs / 2))
        #expect(try await store.database.clearHistoryPreview(range: .lastHour, includeExempt: false).get().count == 1)
    }

    /// OC-8055. 20 items; All time previews 20 and Cancel (no clear call) leaves all 20.
    @Test func oc8055_cancelAllTimeLeavesAllTwenty() async throws {
        // given 20 items
        let store = try await Store.make(); defer { store.cleanUp() }
        try await store.insert((1...20).map { Spec(n: $0, ageMs: Int64($0) * hourMs, blobs: 1, repBytes: 10) })

        // when All time is previewed and the dialog is cancelled
        #expect(try await store.database.clearHistoryPreview(range: .allTime, includeExempt: false).get().count == 20)

        // then count delta 0 and every item present
        #expect(try store.count("item") == 20)
        #expect(try store.presentIds() == Set(1...20))
    }

    /// OC-8056. 3 items from the last hour (H1...H3) and 5 from 3 days ago (O1...O5); Last hour + Delete removes
    /// exactly the 3 recent ones.
    /// Red if the range reaches back further than an hour, or removes anything but the H items.
    @Test func oc8056_lastHourDeleteRemovesOnlyTheRecentThree() async throws {
        // given H1...H3 (n 1...3, 5 to 50 minutes old) and O1...O5 (n 4...8, 3 days old)
        let store = try await Store.make(); defer { store.cleanUp() }
        var specs = (1...3).map { Spec(n: $0, ageMs: Int64($0) * 15 * 60_000 - 10 * 60_000, blobs: 1, repBytes: 10) }
        specs += (4...8).map { Spec(n: $0, ageMs: 3 * dayMs + Int64($0) * 1000, blobs: 1, repBytes: 10) }
        try await store.insert(specs)
        #expect(try await store.database.clearHistoryPreview(range: .lastHour, includeExempt: false).get().count == 3)

        // when the user confirms Delete
        let outcome = try await store.database.clearHistory(range: .lastHour, includeExempt: false).get()

        // then exactly 3 go (H1...H3), the 5 older stay
        #expect(outcome.deletedCount == 3)
        #expect(try store.count("item") == 5)
        #expect(try store.presentIds() == Set(4...8))
        #expect(!store.exists(store.blobURL(1, 1)))
        #expect(store.exists(store.blobURL(4, 1)))
    }
}
