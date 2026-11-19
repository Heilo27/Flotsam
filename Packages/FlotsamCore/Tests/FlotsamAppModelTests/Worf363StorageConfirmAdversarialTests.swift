import Foundation
import os
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-363 blind QA (Worf): adversarial tests for the destructive Storage-pane paths, written from FRD-007 FR-007-09 /
// FR-007-11 and the oracle (OC-7062, 7063, 7080, 7081, 7088, 8054), not from the builder's tests. The fake storage
// here hands every count preview to the test as an open question the test answers in any order, so out-of-order
// answers, rapid toggling and "press Delete while counting" are driven exactly. Nothing touches real preferences, the
// real database, the Keychain or a window. Expected values are literals; the retention and budget orders are written
// out here, not read from production.

// MARK: - Fakes

private final class Log: @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let range: ClearRange
        let exempt: Bool
    }

    struct State {
        var clears: [Call] = []
        var previews: [Call] = []
        var reported: [ErrorCode] = []
        var huds: [String] = []
        var closes = 0
        var sweeps: [String] = []
        var retentionPreviews: [RetentionPreset] = []
        var budgetPreviews: [ImageBudget] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var snapshot: State { state.withLock { $0 } }
    func update(_ change: @Sendable (inout State) -> Void) { state.withLock { change(&$0) } }
}

/// Holds every count question open until the test answers it, by the order it was asked.
private actor Desk {
    private var conts: [CheckedContinuation<Int, Never>] = []
    private var asked: [(range: ClearRange, exempt: Bool)] = []

    func ask(_ range: ClearRange, _ exempt: Bool) async -> Int {
        await withCheckedContinuation { continuation in
            asked.append((range, exempt))
            conts.append(continuation)
        }
    }

    var askedCount: Int { asked.count }
    func question(_ index: Int) -> (ClearRange, Bool) { asked[index] }
    func answer(_ index: Int, count: Int) { conts[index].resume(returning: count) }
}

/// A one-shot latch the fake clear waits on. Any number of callers may wait (a model that wrongly makes a second call
/// must fail its test, not strand the first), and a release after 5 seconds means a latch that is never opened fails
/// on its assertions instead of hanging.
private actor Latch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        let release = Task { [self] in
            try? await Task.sleep(for: .seconds(5))
            open()
        }
        await withCheckedContinuation { waiters.append($0) }
        release.cancel()
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@MainActor private func settle() async { for _ in 0..<40 { await Task.yield() } }

/// Waits until the fake storage has been asked `n` count questions.
@MainActor private func waitForQuestions(_ desk: Desk, _ n: Int) async {
    for _ in 0..<5000 {
        if await desk.askedCount >= n { return }
        await Task.yield()
    }
}

// MARK: - Clear History sheet (FR-007-11, OC-7088, OC-8054)

@MainActor
@Suite struct Worf363ClearHistoryAdversarialTests {
    @MainActor private struct Rig {
        let log = Log()
        let desk = Desk()
        let latch = Latch()
        let model: ClearHistoryModel

        init(deleted: Int = 0, holdClear: Bool = false, failPreviews: Bool = false) {
            let log = log
            let desk = desk
            let latch = latch
            var storage = SettingsStorage(database: { nil })
            storage.clearPreview = { range, exempt in
                log.update { $0.previews.append(.init(range: range, exempt: exempt)) }
                let count = await desk.ask(range, exempt)
                if failPreviews { return .failure(FlotsamError(.stoDb004, "fake preview failure")) }
                return .success(DeletionPreview(count: count, bytes: 0))
            }
            storage.clear = { range, exempt in
                log.update { $0.clears.append(.init(range: range, exempt: exempt)) }
                if holdClear { await latch.wait() }
                return .success(ClearOutcome(deletedCount: deleted, checkpointCompleted: true))
            }
            model = ClearHistoryModel(
                storage: storage,
                report: { error in log.update { $0.reported.append(error.code) } },
                hud: { message in log.update { $0.huds.append(message) } },
                onClose: { log.update { $0.closes += 1 } })
        }

        /// What the view does: run the refresh for the choice on screen. Returns the running request.
        func refresh() -> Task<Void, Never> {
            let model = model
            return Task { @MainActor in await model.refreshPreview() }
        }
    }

    /// OC-7088 / FR-007-11. A count for an earlier choice arrives after the count for the current choice.
    /// Given Last hour is asked (slow), then the user picks All time (fast), when All time answers 7 and then the late
    /// Last hour answer 99 arrives, then the sheet still says 7 and Delete removes All time.
    /// Red if a late answer overwrites the newer one (the stale-preview race), or the count is shown for the wrong key.
    @Test("OC-7088 a late count for the earlier range is discarded")
    func lateCountForEarlierRangeIsDiscarded() async {
        let rig = Rig(deleted: 7)
        let first = rig.refresh()
        await waitForQuestions(rig.desk, 1)
        rig.model.range = .allTime
        let second = rig.refresh()
        await waitForQuestions(rig.desk, 2)
        await rig.desk.answer(1, count: 7)
        await second.value
        #expect(rig.model.countText == "This permanently deletes 7 items. This can\u{2019}t be undone.")
        #expect(rig.model.canDelete)
        // the late answer for Last hour
        await rig.desk.answer(0, count: 99)
        await first.value
        #expect(rig.model.countText == "This permanently deletes 7 items. This can\u{2019}t be undone.")
        #expect(rig.model.count == 7)
        #expect(rig.model.previewKey == PreviewKey(range: .allTime, includeExempt: false))
        await rig.model.delete().value
        #expect(rig.log.snapshot.clears == [.init(range: .allTime, exempt: false)])
        #expect(rig.log.snapshot.huds == ["7 items deleted"])
    }

    /// Same key asked twice (A, B, A) with the older A answering last: the older answer is from before the newer one
    /// and must not replace it. Given A#1 slow, switch to B, back to A#3; A#3 answers 3, then A#1 answers 5.
    /// Then the sheet says 3. Red if only the key is compared and the request order is not.
    @Test("OC-7088 an older answer for the same choice does not replace the newer one")
    func olderSameChoiceAnswerIsDropped() async {
        let rig = Rig(deleted: 3)
        let r1 = rig.refresh()
        await waitForQuestions(rig.desk, 1)
        rig.model.range = .last24Hours
        let r2 = rig.refresh()
        await waitForQuestions(rig.desk, 2)
        rig.model.range = .lastHour
        let r3 = rig.refresh()
        await waitForQuestions(rig.desk, 3)
        await rig.desk.answer(2, count: 3)
        await r3.value
        await rig.desk.answer(0, count: 5)
        await r1.value
        await rig.desk.answer(1, count: 8)
        await r2.value
        #expect(rig.model.count == 3)
        #expect(rig.model.countText == "This permanently deletes 3 items. This can\u{2019}t be undone.")
    }

    /// Rapid toggling through every range and both options (6 requests), answered in forward order except the last.
    /// While the last is open the sheet is counting and Delete does nothing; when the last lands only its count shows.
    /// Red if any earlier answer is accepted as the current count, or Delete works while the current count is missing.
    @Test("OC-7088 rapid toggling: only the last choice's count ever lands")
    func rapidTogglingOnlyLastLands() async {
        let rig = Rig(deleted: 1)
        var runs: [Task<Void, Never>] = []
        let choices: [(ClearRange, Bool)] = [
            (.lastHour, false), (.last24Hours, false), (.allTime, false), (.allTime, true), (.last24Hours, true),
            (.lastHour, true),
        ]
        for (index, choice) in choices.enumerated() {
            rig.model.range = choice.0
            rig.model.includeExempt = choice.1
            runs.append(rig.refresh())
            await waitForQuestions(rig.desk, index + 1)
        }
        for index in 0..<5 {
            await rig.desk.answer(index, count: 100 + index)
            await runs[index].value
            #expect(rig.model.isCounting, "answer \(index) is for an earlier choice")
            #expect(rig.model.countText == "Counting items\u{2026}")
            #expect(!rig.model.canDelete)
            await rig.model.delete().value
            #expect(rig.log.snapshot.clears.isEmpty, "Delete while counting must delete nothing")
        }
        await rig.desk.answer(5, count: 11)
        await runs[5].value
        #expect(rig.model.countText == "This permanently deletes 11 items. This can\u{2019}t be undone.")
        await rig.model.delete().value
        #expect(rig.log.snapshot.clears == [.init(range: .lastHour, exempt: true)])
    }

    /// The same six requests answered newest-first: the newest lands, every later (older) answer is dropped.
    @Test("OC-7088 rapid toggling answered newest-first keeps the newest count")
    func rapidTogglingReverseOrder() async {
        let rig = Rig(deleted: 1)
        var runs: [Task<Void, Never>] = []
        let choices: [(ClearRange, Bool)] = [
            (.lastHour, false), (.last24Hours, false), (.allTime, false), (.allTime, true), (.last24Hours, true),
            (.lastHour, true),
        ]
        for (index, choice) in choices.enumerated() {
            rig.model.range = choice.0
            rig.model.includeExempt = choice.1
            runs.append(rig.refresh())
            await waitForQuestions(rig.desk, index + 1)
        }
        for index in stride(from: 5, through: 0, by: -1) {
            await rig.desk.answer(index, count: 100 + index)
            await runs[index].value
        }
        #expect(rig.model.count == 105)
        #expect(rig.model.previewKey == PreviewKey(range: .lastHour, includeExempt: true))
    }

    /// Delete pressed while the first count is still loading (sheet just opened).
    /// Given nothing answered, when Delete is pressed, then nothing is deleted and the sheet does not close;
    /// once the count lands the same press deletes with the on-screen choice.
    @Test("OC-7088 pressing Delete while counting deletes nothing")
    func deleteDuringCountingIsNoOp() async {
        let rig = Rig(deleted: 4)
        let run = rig.refresh()
        await waitForQuestions(rig.desk, 1)
        #expect(rig.model.countText == "Counting items\u{2026}")
        #expect(!rig.model.canDelete)
        await rig.model.delete().value
        await settle()
        #expect(rig.log.snapshot.clears.isEmpty)
        #expect(rig.log.snapshot.closes == 0)
        #expect(!rig.model.deleting)
        await rig.desk.answer(0, count: 4)
        await run.value
        #expect(rig.model.canDelete)
        await rig.model.delete().value
        #expect(rig.log.snapshot.clears == [.init(range: .lastHour, exempt: false)])
        #expect(rig.log.snapshot.closes == 1)
    }

    /// "Also delete pinned and shortcut items" flipped while the count is in flight (and again after it landed).
    /// Given (All time, off) is in flight, when the box is ticked, then the old answer is dropped, Delete is disabled
    /// and a press deletes nothing; the new answer 50 enables Delete and the clear runs with the box ticked.
    /// Red if the box is ignored by the preview key, or the clear uses the value from before the tick.
    @Test("OC-7088 ticking 'also delete pinned and shortcut items' mid-count discards the count and scopes the delete")
    func optionToggledMidCount() async {
        let rig = Rig(deleted: 48)
        rig.model.range = .allTime
        let first = rig.refresh()
        await waitForQuestions(rig.desk, 1)
        rig.model.includeExempt = true
        let second = rig.refresh()
        await waitForQuestions(rig.desk, 2)
        let q0 = await rig.desk.question(0)
        let q1 = await rig.desk.question(1)
        #expect(q0.0 == .allTime && q0.1 == false)
        #expect(q1.0 == .allTime && q1.1 == true)
        await rig.desk.answer(0, count: 45)
        await first.value
        #expect(rig.model.countText == "Counting items\u{2026}")
        #expect(!rig.model.canDelete)
        await rig.model.delete().value
        #expect(rig.log.snapshot.clears.isEmpty)
        await rig.desk.answer(1, count: 50)
        await second.value
        #expect(rig.model.countText == "This permanently deletes 50 items. This can\u{2019}t be undone.")
        await rig.model.delete().value
        #expect(rig.log.snapshot.clears == [.init(range: .allTime, exempt: true)])
        // the HUD announces what was actually deleted (48), not the preview (50)
        #expect(rig.log.snapshot.huds == ["48 items deleted"])
    }

    /// After a count has landed, changing the choice makes Delete unavailable at once (before any new question is
    /// answered), and a press deletes nothing. Red if the old count stays actionable for the new choice.
    @Test("OC-7088 changing the choice after a count landed disables Delete immediately")
    func changingChoiceAfterLandDisablesDelete() async {
        let rig = Rig(deleted: 5)
        let run = rig.refresh()
        await waitForQuestions(rig.desk, 1)
        await rig.desk.answer(0, count: 5)
        await run.value
        #expect(rig.model.canDelete)
        rig.model.includeExempt = true
        #expect(!rig.model.canDelete)
        #expect(rig.model.countText == "Counting items\u{2026}")
        await rig.model.delete().value
        rig.model.range = .allTime
        await rig.model.delete().value
        #expect(rig.log.snapshot.clears.isEmpty)
    }

    /// Delete scope matrix: for every range and both option values, the clear is called with exactly that pair.
    /// Red if the range or the option is hard-coded, swapped, or read from the wrong place.
    @Test("FR-007-11 the delete scope is exactly the chosen range and option")
    func deleteScopeMatrix() async {
        let ranges: [ClearRange] = [.lastHour, .last24Hours, .allTime]
        for range in ranges {
            for exempt in [false, true] {
                let rig = Rig(deleted: 2)
                rig.model.range = range
                rig.model.includeExempt = exempt
                let run = rig.refresh()
                await waitForQuestions(rig.desk, 1)
                let asked = await rig.desk.question(0)
                #expect(asked.0 == range && asked.1 == exempt)
                await rig.desk.answer(0, count: 2)
                await run.value
                await rig.model.delete().value
                #expect(rig.log.snapshot.clears == [.init(range: range, exempt: exempt)])
                #expect(rig.log.snapshot.closes == 1)
            }
        }
    }

    /// While a delete is running a second press does nothing, a change of range does not re-aim the running delete,
    /// the button reads "Deleting…" and the HUD announces the real count once.
    @Test("FR-007-11 a second press or a range change during the delete does not delete again or elsewhere")
    func deleteInFlightIsOneShot() async {
        let rig = Rig(deleted: 3, holdClear: true)
        let run = rig.refresh()
        await waitForQuestions(rig.desk, 1)
        await rig.desk.answer(0, count: 3)
        await run.value
        let first = rig.model.delete()
        #expect(rig.model.deleting)
        #expect(rig.model.deleteTitle.text == "Deleting\u{2026}")
        #expect(!rig.model.canDelete)
        let second = rig.model.delete()
        rig.model.range = .allTime
        await settle()
        #expect(rig.log.snapshot.clears == [.init(range: .lastHour, exempt: false)])
        await rig.latch.open()
        await second.value
        await first.value
        #expect(rig.log.snapshot.clears == [.init(range: .lastHour, exempt: false)])
        #expect(rig.log.snapshot.huds == ["3 items deleted"])
        #expect(rig.log.snapshot.closes == 1)
        #expect(!rig.model.deleting)
    }

    /// Cancel closes the sheet and deletes nothing, whether or not a count has landed.
    @Test("OC-7088 Cancel never deletes")
    func cancelNeverDeletes() async {
        let rig = Rig(deleted: 9)
        let run = rig.refresh()
        await waitForQuestions(rig.desk, 1)
        rig.model.cancel()
        await rig.desk.answer(0, count: 9)
        await run.value
        rig.model.cancel()
        await settle()
        #expect(rig.log.snapshot.clears.isEmpty)
        #expect(rig.log.snapshot.closes == 2)
    }

    /// OC-8054 / AC-007-09 empty boundary. Count 0: Delete disabled, the empty text, a press deletes nothing, and the
    /// boundary 1 reads singular and enables Delete.
    @Test("OC-8054 count 0 disables Delete with the empty text; count 1 reads singular")
    func zeroAndOneBoundary() async {
        let rig = Rig(deleted: 1)
        let run = rig.refresh()
        await waitForQuestions(rig.desk, 1)
        await rig.desk.answer(0, count: 0)
        await run.value
        #expect(rig.model.countText == "Nothing to clear in this range.")
        #expect(!rig.model.canDelete)
        await rig.model.delete().value
        #expect(rig.log.snapshot.clears.isEmpty)
        rig.model.range = .last24Hours
        let again = rig.refresh()
        await waitForQuestions(rig.desk, 2)
        await rig.desk.answer(1, count: 1)
        await again.value
        #expect(rig.model.countText == "This permanently deletes 1 item. This can\u{2019}t be undone.")
        #expect(rig.model.canDelete)
    }

    /// Labels (ruling: DESIGN.md section 10 deviation, 15-character button limit, count in the sheet sentence).
    /// Red if the button or the checkbox wording changes, or the count moves onto the button.
    @Test("FR-007-11 labels: Delete Items, Also delete pinned and shortcut items, count in the sentence")
    func labels() {
        let rig = Rig()
        #expect(rig.model.deleteTitle.text == "Delete Items")
        #expect(rig.model.deleteTitle.text.count <= 15)
        #expect(SettingsString.clearIncludeExempt.text == "Also delete pinned and shortcut items")
        #expect(rig.model.ranges == [.lastHour, .last24Hours, .allTime])
        #expect(SettingsString.rangeLastHour.text == "Last hour")
        #expect(SettingsString.rangeLast24Hours.text == "Last 24 hours")
        #expect(SettingsString.rangeAllTime.text == "All time")
        #expect(rig.model.includeExempt == false)
    }

    /// DEFECT (Minor). After a count landed for Last hour, the user flips to Last 24 hours and back to Last hour
    /// before the 24 hours answer arrives. FR-007-11 says the text reads "Counting items..." and Delete is disabled
    /// "after each change of range or option" until the count for the current choice has loaded. The model keys the
    /// old preview by (range, option), so the earlier Last hour count is shown as current again with Delete enabled.
    @Test("FR-007-11 returning to an earlier choice shows Counting until the refreshed count lands")
    func returnToEarlierChoiceCounts() async {
        let rig = Rig(deleted: 5)
        let first = rig.refresh()
        await waitForQuestions(rig.desk, 1)
        await rig.desk.answer(0, count: 5)
        await first.value
        rig.model.range = .last24Hours
        let second = rig.refresh()
        await waitForQuestions(rig.desk, 2)
        rig.model.range = .lastHour
        let third = rig.refresh()
        await waitForQuestions(rig.desk, 3)
        #expect(rig.model.countText == "Counting items\u{2026}")
        #expect(!rig.model.canDelete)
        await rig.desk.answer(1, count: 8)
        await rig.desk.answer(2, count: 6)
        await second.value
        await third.value
        #expect(rig.model.count == 6)
    }

    /// DEFECT (Minor). A failed count is shown as "Nothing to clear in this range." and nothing is reported, while the
    /// retention and budget previews report the failure. Delete stays disabled, so no data is at risk.
    @Test("FR-007-11 a failed count is reported, not shown as an empty range")
    func failedPreviewIsReported() async {
        let rig = Rig(failPreviews: true)
        let run = rig.refresh()
        await waitForQuestions(rig.desk, 1)
        await rig.desk.answer(0, count: 0)
        await run.value
        #expect(!rig.model.canDelete)
        #expect(rig.log.snapshot.reported == [.stoDb004])
    }
}

// MARK: - Retention and budget confirmations (FR-007-09, OC-7062/7063/7080/7081)

@MainActor
@Suite struct Worf363StorageConfirmMatrixTests {
    private final class MemoryKV: KeyValueStore, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (values: [String: String](), writes: 0))
        func string(forKey key: String) -> String? { state.withLock { $0.values[key] } }
        func setString(_ value: String, forKey key: String) { state.withLock { $0.values[key] = value; $0.writes += 1 } }
        func removeValue(forKey key: String) { state.withLock { $0.values[key] = nil; $0.writes += 1 } }
        var writes: Int { state.withLock { $0.writes } }
        func seed(_ value: String, forKey key: String) { state.withLock { $0.values[key] = value } }
        func resetWrites() { state.withLock { $0.writes = 0 } }
    }

    @MainActor private struct Rig {
        let kv = MemoryKV()
        let log = Log()
        let model: StorageChangeModel

        init(retention: RetentionPreset, budget: ImageBudget, count: Int) {
            kv.seed(retention.persisted, forKey: SettingKeys.storageRetention.name)
            kv.seed(budget.persisted, forKey: SettingKeys.storageImageBudget.name)
            let log = log
            var storage = SettingsStorage(database: { nil })
            storage.retentionPreview = { preset in
                log.update { $0.retentionPreviews.append(preset) }
                return .success(DeletionPreview(count: count, bytes: 1_000))
            }
            storage.budgetPreview = { budget in
                log.update { $0.budgetPreviews.append(budget) }
                return .success(DeletionPreview(count: count, bytes: 1_000))
            }
            storage.sweep = { preset, budget in
                log.update { $0.sweeps.append("\(preset.rawValue)/\(budget.rawValue)") }
                return .success(SweepOutcome(
                    retentionDeleted: 0, budget: BudgetOutcome(evictedCount: 0, evictedBytes: 0, notice: nil)))
            }
            storage.usage = { .success(StorageUsage(totalItems: 0, imageBytes: 0, databaseBytes: 0)) }
            storage.clear = { range, exempt in
                log.update { $0.clears.append(.init(range: range, exempt: exempt)) }
                return .success(ClearOutcome(deletedCount: 0, checkpointCompleted: true))
            }
            model = StorageChangeModel(settings: SettingsStore(store: kv), storage: storage, report: { error in
                log.update { $0.reported.append(error.code) }
            })
            kv.resetWrites()
        }

        var storedRetention: RetentionPreset { SettingsStore(store: kv).value(SettingKeys.storageRetention) }
        var storedBudget: ImageBudget { SettingsStore(store: kv).value(SettingKeys.storageImageBudget) }
    }

    /// The order of the presets, shortest first, written out here.
    private static let retentionOrder: [RetentionPreset] = [.d7, .d30, .d90, .y1, .forever]
    private static let budgetOrder: [ImageBudget] = [.mib500, .gib2, .gib10, .unlimited]

    /// FR-007-09 / OC-7080 / OC-7081 for every ordered pair of retention presets. A shorter preset with items to
    /// delete asks first and writes and sweeps nothing before the answer; Cancel leaves the stored value and the
    /// sweeps untouched; Delete writes the new value and sweeps exactly once with it. A longer or equal preset never
    /// previews, never asks.
    /// Red if any shrink skips the confirmation (including Forever to a preset), Cancel writes, or a raise asks.
    @Test("FR-007-09 every retention shrink asks first; Cancel leaves setting and data; Delete sweeps once")
    func everyRetentionShrinkAsks() async throws {
        for (oldIndex, old) in Self.retentionOrder.enumerated() {
            for (newIndex, new) in Self.retentionOrder.enumerated() {
                let rig = Rig(retention: old, budget: .gib2, count: 5)
                await rig.model.requestRetention(new, from: old).value
                if newIndex < oldIndex {
                    let pending = try #require(rig.model.pending, "\(old) -> \(new) must ask")
                    #expect(rig.log.snapshot.retentionPreviews == [new])
                    #expect(rig.kv.writes == 0)
                    #expect(rig.log.snapshot.sweeps.isEmpty)
                    #expect(pending.message.hasPrefix("This permanently deletes 5 items older than "))
                    rig.model.cancel()
                    await settle()
                    #expect(rig.model.pending == nil)
                    #expect(rig.storedRetention == old)
                    #expect(rig.kv.writes == 0)
                    #expect(rig.log.snapshot.sweeps.isEmpty)
                    // asked again, then confirmed
                    await rig.model.requestRetention(new, from: old).value
                    await rig.model.confirm(try #require(rig.model.pending)).value
                    #expect(rig.storedRetention == new)
                    #expect(rig.log.snapshot.sweeps == ["\(new.rawValue)/gib2"])
                    #expect(rig.model.pending == nil)
                } else {
                    #expect(rig.model.pending == nil, "\(old) -> \(new) must not ask")
                    #expect(rig.log.snapshot.retentionPreviews.isEmpty)
                }
            }
        }
    }

    /// OC-7062 / OC-7063 for every ordered pair of image budgets, same shape as above.
    @Test("FR-007-09 every image-budget shrink asks first; Cancel leaves setting and data; confirm sweeps once")
    func everyBudgetShrinkAsks() async throws {
        for (oldIndex, old) in Self.budgetOrder.enumerated() {
            for (newIndex, new) in Self.budgetOrder.enumerated() {
                let rig = Rig(retention: .d30, budget: old, count: 3)
                await rig.model.requestBudget(new, from: old).value
                if newIndex < oldIndex {
                    let pending = try #require(rig.model.pending, "\(old) -> \(new) must ask")
                    #expect(rig.log.snapshot.budgetPreviews == [new])
                    #expect(rig.kv.writes == 0)
                    #expect(rig.log.snapshot.sweeps.isEmpty)
                    #expect(pending.title == "Lower the image budget?")
                    #expect(pending.message.hasPrefix("Lowering the image budget removes 3 older images ("))
                    rig.model.cancel()
                    await settle()
                    #expect(rig.storedBudget == old)
                    #expect(rig.kv.writes == 0)
                    #expect(rig.log.snapshot.sweeps.isEmpty)
                    await rig.model.requestBudget(new, from: old).value
                    await rig.model.confirm(try #require(rig.model.pending)).value
                    #expect(rig.storedBudget == new)
                    #expect(rig.log.snapshot.sweeps == ["d30/\(new.rawValue)"])
                } else {
                    #expect(rig.model.pending == nil, "\(old) -> \(new) must not ask")
                    #expect(rig.log.snapshot.budgetPreviews.isEmpty)
                }
            }
        }
    }

    /// A shrink whose preview says nothing would be deleted applies at once with no alert (FR-007-09, count 0); the
    /// boundary count 1 asks. Red if 0 asks, or 1 does not.
    @Test("FR-007-09 count 0 applies at once, count 1 asks (singular)")
    func zeroAppliesOneAsks() async throws {
        let none = Rig(retention: .d90, budget: .gib2, count: 0)
        await none.model.requestRetention(.d7, from: .d90).value
        #expect(none.model.pending == nil)
        #expect(none.storedRetention == .d7)
        #expect(none.log.snapshot.sweeps == ["d7/gib2"])
        let one = Rig(retention: .d90, budget: .gib2, count: 1)
        await one.model.requestRetention(.d7, from: .d90).value
        let pending = try #require(one.model.pending)
        #expect(pending.message == "This permanently deletes 1 item older than 7 days. Pinned items and items with a shortcut are kept.")
        #expect(one.storedRetention == .d90)
    }

    /// Change of mind: a shrink is pending, the user cancels, then picks a different shrink. The first alert's
    /// choice must not leak into the second: only the second value is stored on confirm.
    @Test("FR-007-09 Cancel then a different shrink writes only the second value")
    func cancelThenOtherShrink() async throws {
        let rig = Rig(retention: .forever, budget: .gib2, count: 4)
        await rig.model.requestRetention(.d7, from: .forever).value
        rig.model.cancel()
        await rig.model.requestRetention(.y1, from: .forever).value
        await rig.model.confirm(try #require(rig.model.pending)).value
        #expect(rig.storedRetention == .y1)
        #expect(rig.log.snapshot.sweeps == ["y1/gib2"])
        #expect(rig.log.snapshot.retentionPreviews == [.d7, .y1])
    }
}
