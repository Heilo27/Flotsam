import AppKit
import FlotsamBase
import FlotsamStorage
import SwiftUI

/// Storage (FR-008-08 / FR-007-08 / -09 / -12): retention, image limit, image quality, capture mode, usage and Clear
/// History. A reducing change previews first and asks only when something would be deleted; Cancel leaves the control
/// where it was because the setting is only written after the answer.
struct StoragePane: View {
    let model: SettingsModel
    @State private var changes: StorageChangeModel
    @State private var showingClear = false

    init(model: SettingsModel) {
        self.model = model
        _changes = State(initialValue: StorageChangeModel(
            settings: model.env.settings, storage: model.env.storage, report: model.env.report))
    }

    var body: some View {
        let retention = model.value(SettingKeys.storageRetention)
        let budget = model.value(SettingKeys.storageImageBudget)
        let quality = model.value(SettingKeys.storageImageQuality)
        let mode = model.value(SettingKeys.captureMode)
        Form {
            Section {
                Picker(selection: Binding(get: { retention }, set: { changes.requestRetention($0, from: retention) })) {
                    ForEach(RetentionPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { Text(.keepHistoryFor) }
                Text(.keepHelp).settingsCaption()
                Picker(selection: Binding(get: { budget }, set: { changes.requestBudget($0, from: budget) })) {
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
        .task { await changes.loadUsage() }
        .alert(changes.pending?.title ?? "", isPresented: Binding(get: { changes.pending != nil }, set: { if !$0 { changes.cancel() } }),
            presenting: changes.pending
        ) { change in
            Button(SettingsString.resetAction.text, role: .destructive) { changes.confirm(change) }
            Button(SettingsString.cancel.text, role: .cancel) { changes.cancel() }
        } message: { change in
            Text(verbatim: change.message)
        }
        .sheet(isPresented: $showingClear) {
            ClearHistorySheet(model: model) {
                showingClear = false
                Task { await changes.loadUsage() }
            }
        }
    }

    @ViewBuilder
    private var usageRows: some View {
        switch changes.usage {
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
}

/// Clear History (FR-007-12): a range, an "include pinned and shortcut items" switch, the count that would go, and a
/// Delete that stays disabled while nothing would be deleted.
private struct ClearHistorySheet: View {
    @State private var clear: ClearHistoryModel

    init(model: SettingsModel, onClose: @escaping @MainActor () -> Void) {
        _clear = State(initialValue: ClearHistoryModel(
            storage: model.env.storage, report: model.env.report, hud: model.env.hud, onClose: onClose))
    }

    var body: some View {
        @Bindable var clear = clear
        Form {
            Picker(selection: $clear.range) {
                ForEach(clear.ranges, id: \.self) { Text($0.label).tag($0) }
            } label: { Text(.clearRange) }
            Toggle(isOn: $clear.includeExempt) { Text(.clearIncludeExempt) }
            Text(verbatim: clear.countText)
            HStack {
                Spacer()
                Button(role: .cancel) { clear.cancel() } label: { Text(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) { clear.delete() } label: { Text(clear.deleteTitle) }
                    .disabled(!clear.canDelete)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: PreviewKey(range: clear.range, includeExempt: clear.includeExempt)) {
            await clear.refreshPreview()
        }
    }

    private struct PreviewKey: Hashable {
        let range: ClearRange
        let includeExempt: Bool
    }
}

extension Text {
    fileprivate init(_ string: SettingsString?) { self.init(verbatim: string?.text ?? "") }
}
