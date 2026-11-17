import AppKit
import FlotsamBase
import FlotsamStorage
import SwiftUI

/// Storage (FR-008-08 / FR-007-08 / -09 / -12): retention, image limit, image quality, capture mode, usage and Clear
/// History. A reducing change previews first and asks only when something would be deleted; Cancel leaves the control
/// where it was because the setting is only written after the answer.
struct StoragePane: View {
    let model: SettingsModel
    @State private var usage: FlotsamResult<StorageUsage>?
    @State private var pending: PendingChange?
    @State private var showingClear = false

    /// A reducing change waiting on the user's answer.
    private struct PendingChange: Identifiable {
        enum Kind { case retention(RetentionPreset), budget(ImageBudget, bytes: Int64) }
        let id = UUID()
        let kind: Kind
        let count: Int
    }

    var body: some View {
        let retention = model.value(SettingKeys.storageRetention)
        let budget = model.value(SettingKeys.storageImageBudget)
        let quality = model.value(SettingKeys.storageImageQuality)
        let mode = model.value(SettingKeys.captureMode)
        Form {
            Section {
                Picker(selection: Binding(get: { retention }, set: { requestRetention($0, from: retention) })) {
                    ForEach(RetentionPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { Text(.keepHistoryFor) }
                Text(.keepHelp).settingsCaption()
                Picker(selection: Binding(get: { budget }, set: { requestBudget($0, from: budget) })) {
                    ForEach(ImageBudget.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { Text(.imageLimit) }
                Picker(selection: model.binding(SettingKeys.storageImageQuality)) {
                    ForEach(ImageQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { Text(.imageQuality) }
                Text(quality.caption).settingsCaption()
            }
            Section {
                Picker(selection: model.binding(SettingKeys.captureMode)) {
                    ForEach(CaptureMode.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { Text(.captureMode) }
                Text(mode.caption).settingsCaption()
            }
            Section {
                usageRows
                HStack {
                    Button { model.env.revealDataFolder() } label: { Text(.revealDataFolder) }
                    Spacer()
                    Button(role: .destructive) { showingClear = true } label: { Text(.clearHistory) }
                }
            }
        }
        .settingsPaneChrome()
        .task { await loadUsage() }
        .alert(title(of: pending), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { change in
            Button(SettingsString.resetAction.text, role: .destructive) { confirm(change) }
            Button(SettingsString.cancel.text, role: .cancel) { pending = nil }
        } message: { change in
            Text(verbatim: message(of: change))
        }
        .sheet(isPresented: $showingClear) {
            ClearHistorySheet(model: model) {
                showingClear = false
                Task { await loadUsage() }
            }
        }
    }

    @ViewBuilder
    private var usageRows: some View {
        switch usage {
        case .success(let value):
            LabeledContent { Text(verbatim: value.totalItems.formatted()) } label: { Text(.usageItems) }
            LabeledContent { Text(verbatim: MessageArgument.formatBytes(Int(clamping: value.imageBytes))) } label: {
                Text(.usageImages)
            }
            LabeledContent { Text(verbatim: MessageArgument.formatBytes(Int(clamping: value.databaseBytes))) } label: {
                Text(.usageDatabase)
            }
        case .failure:
            LabeledContent { Text(.usageUnavailable) } label: { Text(.usageItems) }
        case nil:
            EmptyView()
        }
    }

    private func loadUsage() async { usage = await model.env.storage.usage() }

    // MARK: Reducing changes (FR-007-09)

    private func requestRetention(_ new: RetentionPreset, from old: RetentionPreset) {
        guard new != old else { return }
        guard StorageChangeFlow.needsPreview(retention: new, from: old) else { return apply(retention: new) }
        Task {
            switch await model.env.storage.retentionPreview(new) {
            case .success(let preview):
                switch StorageChangeFlow.after(previewCount: preview.count) {
                case .applyNow: apply(retention: new)
                case .confirm(let count): pending = PendingChange(kind: .retention(new), count: count)
                }
            case .failure(let error): model.env.report(error)
            }
        }
    }

    private func requestBudget(_ new: ImageBudget, from old: ImageBudget) {
        guard new != old else { return }
        guard StorageChangeFlow.needsPreview(budget: new, from: old) else { return apply(budget: new) }
        Task {
            switch await model.env.storage.budgetPreview(new) {
            case .success(let preview):
                switch StorageChangeFlow.after(previewCount: preview.count) {
                case .applyNow: apply(budget: new)
                case .confirm(let count): pending = PendingChange(kind: .budget(new, bytes: preview.bytes), count: count)
                }
            case .failure(let error): model.env.report(error)
            }
        }
    }

    private func confirm(_ change: PendingChange) {
        pending = nil
        switch change.kind {
        case .retention(let preset): apply(retention: preset)
        case .budget(let budget, _): apply(budget: budget)
        }
    }

    /// Writes the setting, then sweeps so the change takes effect now rather than at the next scheduled sweep.
    private func apply(retention: RetentionPreset) {
        model.env.settings.set(retention, for: SettingKeys.storageRetention)
        sweep()
    }

    private func apply(budget: ImageBudget) {
        model.env.settings.set(budget, for: SettingKeys.storageImageBudget)
        sweep()
    }

    private func sweep() {
        let retention = model.env.settings.value(SettingKeys.storageRetention)
        let budget = model.env.settings.value(SettingKeys.storageImageBudget)
        Task {
            if case .failure(let error) = await model.env.storage.sweep(retention, budget) { model.env.report(error) }
            await loadUsage()
        }
    }

    private func title(of change: PendingChange?) -> String {
        switch change?.kind {
        case .retention: SettingsString.confirmShortenTitle.text
        case .budget: SettingsString.confirmBudgetTitle.text
        case nil: ""
        }
    }

    private func message(of change: PendingChange) -> String {
        switch change.kind {
        case .retention(let preset): SettingsString.confirmShorten.text(count: change.count, label: preset.label)
        case .budget(_, let bytes):
            SettingsString.confirmBudget.text([.count(change.count), .byteSize(Int(clamping: bytes))])
        }
    }
}

/// Clear History (FR-007-12): a range, an "include pinned and shortcut items" switch, the count that would go, and a
/// Delete that stays disabled while nothing would be deleted.
private struct ClearHistorySheet: View {
    let model: SettingsModel
    let onClose: () -> Void
    @State private var range: ClearRange = .lastHour
    @State private var includeExempt = false
    @State private var preview: FlotsamResult<DeletionPreview>?
    @State private var deleting = false

    var body: some View {
        let count = (try? preview?.get())?.count ?? 0
        Form {
            Picker(selection: $range) {
                ForEach(ClearRange.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: { Text(.clearRange) }
            Toggle(isOn: $includeExempt) { Text(.clearIncludeExempt) }
            Text(verbatim: count > 0 ? SettingsString.clearCount.text([.count(count)]) : SettingsString.clearNothing.text)
            HStack {
                Spacer()
                Button(role: .cancel) { onClose() } label: { Text(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) { delete() } label: { Text(deleting ? .clearDeleting : .clearDelete) }
                    .disabled(count == 0 || deleting)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: PreviewKey(range: range, includeExempt: includeExempt)) {
            preview = await model.env.storage.clearPreview(range, includeExempt)
        }
    }

    private struct PreviewKey: Hashable {
        let range: ClearRange
        let includeExempt: Bool
    }

    private func delete() {
        deleting = true
        Task {
            switch await model.env.storage.clear(range, includeExempt) {
            case .success(let outcome):
                model.env.hud(SettingsString.clearDone.text([.count(outcome.deletedCount)]))
            case .failure(let error):
                model.env.report(error)
            }
            deleting = false
            onClose()
        }
    }
}

extension ClearRange {
    fileprivate var label: SettingsString {
        switch self {
        case .lastHour: .rangeLastHour
        case .last24Hours: .rangeLast24Hours
        case .allTime: .rangeAllTime
        }
    }
}

extension Text {
    fileprivate init(_ string: SettingsString?) { self.init(verbatim: string?.text ?? "") }
}
