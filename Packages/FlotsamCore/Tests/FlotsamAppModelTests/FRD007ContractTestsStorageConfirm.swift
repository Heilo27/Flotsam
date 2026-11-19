import Foundation
import os
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T contract tests, the App half of the destructive Settings > Storage paths (oracle
// .claude/oracle/frd-007-contract.json, FRD-008 FR-008-08): the lower-budget confirmation (OC-7062, OC-7063), the
// shorten-retention confirmation (OC-7080, OC-7081) and the Clear History sheet (OC-7088). The decisions live in
// StorageChangeModel and ClearHistoryModel (App/Flotsam/Settings, compiled into this target by symlink); the SwiftUI
// views only show them. The storage calls are fakes that record what was asked, so a test sees exactly which deletions
// the model requested and when; the database-side halves (rows that stay, delta -n) are in FlotsamStorageTests.
// Nothing here touches the real preferences, database, Keychain or any window. Expected values are literals.

/// An in-memory key-value store that counts writes, so "Cancel wrote nothing" is a number.
private final class MemoryKV: KeyValueStore, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (values: [String: String](), writes: 0))

    func string(forKey key: String) -> String? { state.withLock { $0.values[key] } }
    func setString(_ value: String, forKey key: String) { state.withLock { $0.values[key] = value; $0.writes += 1 } }
    func removeValue(forKey key: String) { state.withLock { $0.values[key] = nil; $0.writes += 1 } }
    var writes: Int { state.withLock { $0.writes } }

    /// Seeds a stored value the way an earlier launch would have left it, without counting as a write.
    func seed(_ value: String, forKey key: String) { state.withLock { $0.values[key] = value } }
    func resetWrites() { state.withLock { $0.writes = 0 } }
}

/// Everything the fake storage and the callbacks were asked to do, in order.
private final class Calls: @unchecked Sendable {
    struct State {
        var sweeps: [String] = []
        var clears: [String] = []
        var clearPreviews: [String] = []
        var retentionPreviews: [RetentionPreset] = []
        var budgetPreviews: [ImageBudget] = []
        var usageLoads = 0
        var reported: [ErrorCode] = []
        var huds: [String] = []
        var closes = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var snapshot: State { state.withLock { $0 } }
    func update(_ change: @Sendable (inout State) -> Void) { state.withLock { change(&$0) } }
}

/// A one-shot gate a fake clear waits on, so a test can look at the model while the deletion is "in flight".
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Lets any work a button press left running on the main actor finish, so "nothing happened" is checked after it could have.
@MainActor private func settle() async { for _ in 0..<30 { await Task.yield() } }

private let quiet = SweepOutcome(
    retentionDeleted: 0, budget: BudgetOutcome(evictedCount: 0, evictedBytes: 0, notice: nil))
private let gib: Int64 = 1024 * 1024 * 1024

// MARK: - Lower budget and shorter retention (FR-007-09, FR-008-08)

@MainActor
@Suite struct FRD007ContractStorageConfirmTests {
    @MainActor private struct Rig {
        let kv = MemoryKV()
        let calls = Calls()
        let model: StorageChangeModel
        let settings: SettingsStore

        /// `retentionPreview` and `budgetPreview` answer these; the sweep and usage fakes just record.
        init(retention: RetentionPreset, budget: ImageBudget, retentionCount: Int = 0, budgetCount: Int = 0,
             budgetBytes: Int64 = 0, previewFails: Bool = false) {
            kv.seed(retention.persisted, forKey: SettingKeys.storageRetention.name)
            kv.seed(budget.persisted, forKey: SettingKeys.storageImageBudget.name)
            let calls = calls
            settings = SettingsStore(store: kv)
            var storage = SettingsStorage(database: { nil })
            let failure = FlotsamError(.stoDb004, "fake preview failure")
            storage.retentionPreview = { preset in
                calls.update { $0.retentionPreviews.append(preset) }
                return previewFails ? .failure(failure) : .success(DeletionPreview(count: retentionCount, bytes: 0))
            }
            storage.budgetPreview = { budget in
                calls.update { $0.budgetPreviews.append(budget) }
                return previewFails ? .failure(failure) : .success(DeletionPreview(count: budgetCount, bytes: budgetBytes))
            }
            storage.sweep = { preset, budget in
                calls.update { $0.sweeps.append("\(preset.rawValue)/\(budget.rawValue)") }
                return .success(quiet)
            }
            storage.usage = {
                calls.update { $0.usageLoads += 1 }
                return .success(StorageUsage(totalItems: 7, imageBytes: 42, databaseBytes: 99))
            }
            storage.clear = { _, _ in
                calls.update { $0.clears.append("unexpected") }
                return .success(ClearOutcome(deletedCount: 0, checkpointCompleted: true))
            }
            model = StorageChangeModel(settings: settings, storage: storage, report: { error in
                calls.update { $0.reported.append(error.code) }
            })
            kv.resetWrites()
        }

        /// What a freshly launched app would read from the same store.
        var storedRetention: RetentionPreset { SettingsStore(store: kv).value(SettingKeys.storageRetention) }
        var storedBudget: ImageBudget { SettingsStore(store: kv).value(SettingKeys.storageImageBudget) }
    }

    // MARK: OC-7062 / OC-7063 lower image budget

    /// OC-7062. Budget 10 GB, the user picks 2 GB, a preview says 13 images would go, and the user clicks Cancel.
    /// The alert asks first; nothing is written or swept before the answer; after Cancel the budget is still 10 GB
    /// (also for a fresh store over the same keys) and nothing was deleted.
    /// Red if the setting is written or the sweep runs before the answer, or Cancel leaves anything behind.
    @Test("OC-7062 lowering the budget asks first; Cancel keeps 10 GB and deletes nothing")
    func oc7062_cancelKeepsBudget() async throws {
        let rig = Rig(retention: .d90, budget: .gib10, budgetCount: 13, budgetBytes: 3 * gib)
        // when the user selects 2 GB
        await rig.model.requestBudget(.gib2, from: .gib10).value
        // then the confirmation shows, with the real count and size, and nothing has been changed yet
        let pending = try #require(rig.model.pending)
        #expect(pending.title == "Lower the image budget?")
        #expect(pending.message == "Lowering the image budget removes 13 older images (3 GB). Pinned and shortcut items are kept.")
        #expect(rig.calls.snapshot.budgetPreviews == [.gib2])
        #expect(rig.kv.writes == 0)
        #expect(rig.calls.snapshot.sweeps.isEmpty)
        // when the user clicks Cancel
        rig.model.cancel()
        await settle()
        // then the popup still reads 10 GB, no setting was written and nothing was swept or cleared
        #expect(rig.model.pending == nil)
        #expect(rig.storedBudget == .gib10)
        #expect(rig.storedRetention == .d90)
        #expect(rig.kv.writes == 0)
        #expect(rig.calls.snapshot.sweeps.isEmpty)
        #expect(rig.calls.snapshot.clears.isEmpty)
    }

    /// OC-7063. The same alert, confirmed. The setting becomes 2 GB and exactly one sweep runs, with the new budget
    /// and the unchanged retention; the alert is gone and the usage line is re-read.
    /// Red if confirm does not write, sweeps more than once, sweeps with the old budget, or leaves the alert up.
    @Test("OC-7063 confirming the lower budget writes 2 GB and sweeps once")
    func oc7063_confirmAppliesBudget() async throws {
        let rig = Rig(retention: .d90, budget: .gib10, budgetCount: 13, budgetBytes: 3 * gib)
        await rig.model.requestBudget(.gib2, from: .gib10).value
        let pending = try #require(rig.model.pending)
        // when the user confirms
        await rig.model.confirm(pending).value
        // then the popup reads 2 GB (a fresh store sees it), one sweep ran with it, the alert is gone, usage reloaded
        #expect(rig.storedBudget == .gib2)
        #expect(rig.storedRetention == .d90)
        #expect(rig.calls.snapshot.sweeps == ["d90/gib2"])
        #expect(rig.model.pending == nil)
        #expect(rig.calls.snapshot.usageLoads == 1)
        #expect(try rig.model.usage?.get() == StorageUsage(totalItems: 7, imageBytes: 42, databaseBytes: 99))
        #expect(rig.calls.snapshot.clears.isEmpty)
    }

    // MARK: OC-7080 / OC-7081 shorter retention

    /// OC-7080. Keep history is Forever, the user picks 7 days, a preview says 60 items would go, and clicks Cancel.
    /// The alert names the count and the period; after Cancel it still reads Forever and no sweep ran.
    /// Red if Cancel writes 7 days or sweeps, or the alert text is wrong.
    @Test("OC-7080 shortening history asks first; Cancel keeps Forever and deletes nothing")
    func oc7080_cancelKeepsForever() async throws {
        let rig = Rig(retention: .forever, budget: .mib500, retentionCount: 60)
        // when the user selects 7 days
        await rig.model.requestRetention(.d7, from: .forever).value
        // then the confirmation shows with the count and the period, and nothing has been changed yet
        let pending = try #require(rig.model.pending)
        #expect(pending.title == "Shorten history?")
        #expect(pending.message == "This permanently deletes 60 items older than 7 days. Pinned items and items with a shortcut are kept.")
        #expect(rig.calls.snapshot.retentionPreviews == [.d7])
        #expect(rig.kv.writes == 0)
        #expect(rig.calls.snapshot.sweeps.isEmpty)
        // when the user clicks Cancel
        rig.model.cancel()
        await settle()
        // then it still reads Forever, nothing was written, swept or cleared
        #expect(rig.model.pending == nil)
        #expect(rig.storedRetention == .forever)
        #expect(rig.storedBudget == .mib500)
        #expect(rig.kv.writes == 0)
        #expect(rig.calls.snapshot.sweeps.isEmpty)
        #expect(rig.calls.snapshot.clears.isEmpty)
    }

    /// OC-7081. The same alert, confirmed. The setting becomes 7 days and exactly one sweep runs with 7 days and the
    /// unchanged budget.
    /// Red if confirm does not write, sweeps more than once, or sweeps with the old retention.
    @Test("OC-7081 confirming the shorter retention writes 7 days and sweeps once")
    func oc7081_confirmAppliesRetention() async throws {
        let rig = Rig(retention: .forever, budget: .mib500, retentionCount: 60)
        await rig.model.requestRetention(.d7, from: .forever).value
        let pending = try #require(rig.model.pending)
        // when the user confirms
        await rig.model.confirm(pending).value
        // then the popup reads 7 days, one sweep ran with it and the unchanged budget, and the alert is gone
        #expect(rig.storedRetention == .d7)
        #expect(rig.storedBudget == .mib500)
        #expect(rig.calls.snapshot.sweeps == ["d7/mib500"])
        #expect(rig.model.pending == nil)
        #expect(rig.calls.snapshot.usageLoads == 1)
        #expect(rig.calls.snapshot.clears.isEmpty)
    }

    // MARK: The rest of the decision (FR-007-09)

    /// A reduction that would delete nothing applies at once with no alert: the preview count is 0.
    /// Red if an empty preview still raises the alert, or the change is not applied and swept.
    @Test("FR-007-09 a reduction that deletes nothing applies without asking")
    func zeroPreviewAppliesAtOnce() async {
        let rig = Rig(retention: .forever, budget: .gib10, retentionCount: 0, budgetCount: 0)
        await rig.model.requestRetention(.d7, from: .forever).value
        #expect(rig.model.pending == nil)
        #expect(rig.storedRetention == .d7)
        #expect(rig.calls.snapshot.sweeps == ["d7/gib10"])
        await rig.model.requestBudget(.gib2, from: .gib10).value
        #expect(rig.model.pending == nil)
        #expect(rig.storedBudget == .gib2)
        #expect(rig.calls.snapshot.sweeps == ["d7/gib10", "d7/gib2"])
    }

    /// Raising or keeping a value never previews, never asks and never wastes the user's time, but still writes and
    /// sweeps (a longer period deletes nothing, and the sweep is the one place that applies the setting).
    /// Red if a raise fetches a preview or raises the alert.
    @Test("FR-007-09 raising a value applies without a preview")
    func raiseNeverPreviews() async {
        let rig = Rig(retention: .d7, budget: .mib500, retentionCount: 99, budgetCount: 99)
        await rig.model.requestRetention(.forever, from: .d7).value
        await rig.model.requestBudget(.gib10, from: .mib500).value
        #expect(rig.model.pending == nil)
        #expect(rig.calls.snapshot.retentionPreviews.isEmpty)
        #expect(rig.calls.snapshot.budgetPreviews.isEmpty)
        #expect(rig.storedRetention == .forever)
        #expect(rig.storedBudget == .gib10)
    }

    /// Choosing the value already stored is not a change: no write, no preview, no sweep.
    /// Red if the same value triggers any storage work.
    @Test("FR-007-09 choosing the stored value does nothing")
    func sameValueIsNoOp() async {
        let rig = Rig(retention: .d30, budget: .gib2, retentionCount: 5, budgetCount: 5)
        await rig.model.requestRetention(.d30, from: .d30).value
        await rig.model.requestBudget(.gib2, from: .gib2).value
        #expect(rig.model.pending == nil)
        #expect(rig.kv.writes == 0)
        #expect(rig.calls.snapshot.sweeps.isEmpty)
        #expect(rig.calls.snapshot.retentionPreviews.isEmpty)
        #expect(rig.calls.snapshot.budgetPreviews.isEmpty)
    }

    /// When the preview cannot be read the change is not made blind: the failure is reported, nothing is written and
    /// nothing is swept, so a database that is not open cannot lead to an unconfirmed deletion.
    /// Red if a failed preview applies the change or swallows the error.
    @Test("FR-007-09 a failed preview reports and changes nothing")
    func previewFailureChangesNothing() async {
        let rig = Rig(retention: .forever, budget: .gib10, previewFails: true)
        await rig.model.requestRetention(.d7, from: .forever).value
        await rig.model.requestBudget(.gib2, from: .gib10).value
        #expect(rig.model.pending == nil)
        #expect(rig.calls.snapshot.reported == [.stoDb004, .stoDb004])
        #expect(rig.kv.writes == 0)
        #expect(rig.calls.snapshot.sweeps.isEmpty)
    }
}

// MARK: - Clear History sheet (FR-007-11)

@MainActor
@Suite struct FRD007ContractClearHistoryTests {
    @MainActor private struct Rig {
        let calls = Calls()
        let model: ClearHistoryModel
        let gate: Gate?

        /// `previewCount` answers every preview; `deleted` is what the clear reports having removed (it differs from
        /// the preview on purpose, as it can in life); `hold` makes the clear wait on `gate`.
        init(previewCount: Int, deleted: Int = 0, clearFails: Bool = false, hold: Bool = false) {
            let calls = calls
            let gate = hold ? Gate() : nil
            self.gate = gate
            var storage = SettingsStorage(database: { nil })
            storage.clearPreview = { range, exempt in
                calls.update { $0.clearPreviews.append("\(range)/\(exempt)") }
                return .success(DeletionPreview(count: previewCount, bytes: 0))
            }
            storage.clear = { range, exempt in
                calls.update { $0.clears.append("\(range)/\(exempt)") }
                if let gate { await gate.wait() }
                if clearFails { return .failure(FlotsamError(.stoDb004, "fake clear failure")) }
                return .success(ClearOutcome(deletedCount: deleted, checkpointCompleted: true))
            }
            storage.sweep = { _, _ in
                calls.update { $0.sweeps.append("unexpected") }
                return .success(quiet)
            }
            model = ClearHistoryModel(
                storage: storage,
                report: { error in calls.update { $0.reported.append(error.code) } },
                hud: { message in calls.update { $0.huds.append(message) } },
                onClose: { calls.update { $0.closes += 1 } })
        }
    }

    /// OC-7088 (sheet half). The sheet opens with the range popup at its first choice, the three ranges in order, the
    /// pinned-and-shortcut checkbox off, and Delete disabled until a count has loaded.
    /// Red if the checkbox starts on (the sheet would delete protected items by default), the choices change or
    /// reorder, or Delete is enabled before there is anything to delete.
    @Test("OC-7088 the sheet opens with Last hour, the box unchecked and Delete disabled")
    func oc7088_initialState() {
        let rig = Rig(previewCount: 12)
        let model = rig.model
        #expect(model.ranges == [.lastHour, .last24Hours, .allTime])
        #expect(model.ranges.map { $0.label.text } == ["Last hour", "Last 24 hours", "All time"])
        #expect(model.range == .lastHour)
        #expect(model.includeExempt == false)
        #expect(model.count == 0)
        #expect(model.canDelete == false)
        #expect(model.deleteTitle == .clearDelete)
        #expect(rig.calls.snapshot.clears.isEmpty)
    }

    /// OC-7088 (count label). With a preview of 12 the label states it and Delete turns on; with 0 the label says
    /// nothing is to be cleared and Delete stays off. The preview is asked for the current range and option.
    /// Red if the count text or the enabled state is wrong, or the preview ignores the range or the checkbox.
    @Test("OC-7088 the count label and Delete follow the preview for the chosen range and option")
    func oc7088_countAndPreviewArguments() async {
        let rig = Rig(previewCount: 12)
        let model = rig.model
        await model.refreshPreview()
        #expect(model.countText == "This permanently deletes 12 items. This can\u{2019}t be undone.")
        #expect(model.canDelete)
        model.range = .allTime
        model.includeExempt = true
        await model.refreshPreview()
        #expect(rig.calls.snapshot.clearPreviews == ["lastHour/false", "allTime/true"])

        let empty = Rig(previewCount: 0)
        await empty.model.refreshPreview()
        #expect(empty.model.countText == "Nothing to clear in this range.")
        #expect(empty.model.canDelete == false)
    }

    /// OC-7088 (Cancel). Cancel closes the sheet and asks storage to delete nothing.
    /// Red if Cancel calls clear, or does not close.
    @Test("OC-7088 Cancel closes the sheet and deletes nothing")
    func oc7088_cancelDeletesNothing() async {
        let rig = Rig(previewCount: 12)
        await rig.model.refreshPreview()
        rig.model.cancel()
        await settle()
        #expect(rig.calls.snapshot.closes == 1)
        #expect(rig.calls.snapshot.clears.isEmpty)
        #expect(rig.calls.snapshot.huds.isEmpty)
        #expect(rig.calls.snapshot.sweeps.isEmpty)
    }

    /// OC-7088 (Delete). Delete asks storage once, for exactly the chosen range and option, announces the number the
    /// deletion actually removed (5, not the earlier preview of 12) and closes the sheet.
    /// Red if the range or option passed is not the one on screen, the HUD uses the preview count, or it clears twice.
    @Test("OC-7088 Delete clears the chosen range once and announces the real count")
    func oc7088_deleteUsesChosenScopeAndRealCount() async {
        let rig = Rig(previewCount: 12, deleted: 5)
        let model = rig.model
        model.range = .last24Hours
        model.includeExempt = true
        await model.refreshPreview()
        await model.delete().value
        #expect(rig.calls.snapshot.clears == ["last24Hours/true"])
        #expect(rig.calls.snapshot.huds == ["5 items deleted"])
        #expect(rig.calls.snapshot.closes == 1)
        #expect(rig.calls.snapshot.reported.isEmpty)
        #expect(model.deleting == false)
    }

    /// With the default scope (the checkbox off) the clear is asked to spare pinned and shortcut items.
    /// Red if the default scope includes exempt items.
    @Test("OC-7088 Delete with the box unchecked asks to keep pinned and shortcut items")
    func oc7088_defaultScopeKeepsExempt() async {
        let rig = Rig(previewCount: 3, deleted: 1)
        await rig.model.refreshPreview()
        await rig.model.delete().value
        #expect(rig.calls.snapshot.clears == ["lastHour/false"])
        #expect(rig.calls.snapshot.huds == ["1 item deleted"])
    }

    /// While the deletion is running Delete is disabled and reads "Deleting...", and a second press does nothing.
    /// Red if Delete stays enabled while deleting, or a second press clears again.
    @Test("OC-7088 while deleting, Delete is disabled and reads Deleting")
    func oc7088_deletingState() async {
        let rig = Rig(previewCount: 12, deleted: 12, hold: true)
        let model = rig.model
        await model.refreshPreview()
        let task = model.delete()
        #expect(model.deleting)
        #expect(model.canDelete == false)
        #expect(model.deleteTitle == .clearDeleting)
        model.delete()
        await rig.gate?.open()
        await task.value
        #expect(rig.calls.snapshot.clears.count == 1)
        #expect(model.deleting == false)
        #expect(model.deleteTitle == .clearDelete)
    }

    /// With nothing to delete, Delete does nothing at all.
    /// Red if a clear runs, or the sheet closes with a "0 items deleted" HUD.
    @Test("OC-7088 Delete with a count of 0 does nothing")
    func oc7088_deleteAtZeroIsNoOp() async {
        let rig = Rig(previewCount: 0)
        await rig.model.refreshPreview()
        await rig.model.delete().value
        await settle()
        #expect(rig.calls.snapshot.clears.isEmpty)
        #expect(rig.calls.snapshot.huds.isEmpty)
        #expect(rig.calls.snapshot.closes == 0)
    }

    /// A failed deletion is reported, shows no "deleted" HUD, and still closes the sheet.
    /// Red if a failure is swallowed, announces a deletion that did not happen, or leaves the sheet stuck on Deleting.
    @Test("OC-7088 a failed deletion reports, shows no HUD and closes")
    func oc7088_deleteFailure() async {
        let rig = Rig(previewCount: 12, clearFails: true)
        await rig.model.refreshPreview()
        await rig.model.delete().value
        #expect(rig.calls.snapshot.reported == [.stoDb004])
        #expect(rig.calls.snapshot.huds.isEmpty)
        #expect(rig.calls.snapshot.closes == 1)
        #expect(rig.model.deleting == false)
    }
}
