import FlotsamBase
import FlotsamStorage
import Foundation
import Observation

/// The decision logic behind the Storage pane's destructive popups (FR-007-09, FR-008-08), lifted out of the SwiftUI
/// view so `swift test` can drive it (compiled into FlotsamAppModelTests by symlink). A reducing change previews first
/// and asks only when something would be deleted; the setting is written, and the sweep run, only after the answer, so
/// Cancel leaves the control where it was and deletes nothing. The view holds no logic of its own: it shows `pending`
/// and forwards the pickers and the alert's buttons here.
@MainActor
@Observable
final class StorageChangeModel {
    /// A reducing change waiting on the user's answer.
    struct PendingChange: Identifiable, Equatable {
        enum Kind: Equatable { case retention(RetentionPreset), budget(ImageBudget, bytes: Int64) }
        let id = UUID()
        let kind: Kind
        let count: Int

        var title: String {
            switch kind {
            case .retention: SettingsString.confirmShortenTitle.text
            case .budget: SettingsString.confirmBudgetTitle.text
            }
        }

        var message: String {
            switch kind {
            case .retention(let preset): SettingsString.confirmShorten.text(count: count, label: preset.label)
            case .budget(_, let bytes): SettingsString.confirmBudget.text([.count(count), .byteSize(Int(clamping: bytes))])
            }
        }
    }

    /// The alert on screen, nil when none is.
    private(set) var pending: PendingChange?
    private(set) var usage: FlotsamResult<StorageUsage>?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let storage: SettingsStorage
    @ObservationIgnored private let report: @MainActor @Sendable (FlotsamError) -> Void

    init(settings: SettingsStore, storage: SettingsStorage, report: @escaping @MainActor @Sendable (FlotsamError) -> Void) {
        self.settings = settings
        self.storage = storage
        self.report = report
    }

    func loadUsage() async { usage = await storage.usage() }

    // MARK: Reducing changes (FR-007-09)

    /// The picker chose `new` while the stored value is `old`. Returns the work in flight so a caller can wait for it.
    @discardableResult
    func requestRetention(_ new: RetentionPreset, from old: RetentionPreset) -> Task<Void, Never> {
        guard new != old else { return Task {} }
        guard StorageChangeFlow.needsPreview(retention: new, from: old) else { return apply(retention: new) }
        return Task {
            switch await storage.retentionPreview(new) {
            case .success(let preview):
                switch StorageChangeFlow.after(previewCount: preview.count) {
                case .applyNow: await apply(retention: new).value
                case .confirm(let count): pending = PendingChange(kind: .retention(new), count: count)
                }
            case .failure(let error): report(error)
            }
        }
    }

    @discardableResult
    func requestBudget(_ new: ImageBudget, from old: ImageBudget) -> Task<Void, Never> {
        guard new != old else { return Task {} }
        guard StorageChangeFlow.needsPreview(budget: new, from: old) else { return apply(budget: new) }
        return Task {
            switch await storage.budgetPreview(new) {
            case .success(let preview):
                switch StorageChangeFlow.after(previewCount: preview.count) {
                case .applyNow: await apply(budget: new).value
                case .confirm(let count): pending = PendingChange(kind: .budget(new, bytes: preview.bytes), count: count)
                }
            case .failure(let error): report(error)
            }
        }
    }

    /// The alert's destructive button: only now is the setting written and the sweep run.
    @discardableResult
    func confirm(_ change: PendingChange) -> Task<Void, Never> {
        pending = nil
        switch change.kind {
        case .retention(let preset): return apply(retention: preset)
        case .budget(let budget, _): return apply(budget: budget)
        }
    }

    /// The alert's Cancel button, or the alert dismissed any other way: nothing was written and nothing is swept.
    func cancel() { pending = nil }

    /// Writes the setting, then sweeps so the change takes effect now rather than at the next scheduled sweep.
    private func apply(retention: RetentionPreset) -> Task<Void, Never> {
        settings.set(retention, for: SettingKeys.storageRetention)
        return sweep()
    }

    private func apply(budget: ImageBudget) -> Task<Void, Never> {
        settings.set(budget, for: SettingKeys.storageImageBudget)
        return sweep()
    }

    private func sweep() -> Task<Void, Never> {
        let retention = settings.value(SettingKeys.storageRetention)
        let budget = settings.value(SettingKeys.storageImageBudget)
        return Task {
            if case .failure(let error) = await storage.sweep(retention, budget) { report(error) }
            await loadUsage()
        }
    }
}
