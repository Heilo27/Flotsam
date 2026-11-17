import AppKit
import FlotsamBase
import FlotsamStorage
import SwiftUI

/// The Settings window content (FR-008-03): one tab per pane, in `SettingsPane` order, remembering the last pane.
/// MVP integration scope: every pane reads and writes the registry through `SettingsModel`; list editing, the shortcut
/// recorder (FRD-005), Clear History and Copy Diagnostics are not built yet.
struct SettingsView: View {
    let model: SettingsModel
    @State private var pane: SettingsPane

    init(model: SettingsModel) {
        self.model = model
        _pane = State(initialValue: SettingsPane.lastOpened(in: model.env.settings))
    }

    var body: some View {
        TabView(selection: $pane) {
            ForEach(SettingsPane.allCases, id: \.self) { pane in
                paneView(pane)
                    .tabItem { Label(pane.title.text, systemImage: pane.symbolName) }
                    .tag(pane)
            }
        }
        .onChange(of: pane) { _, new in new.remember(in: model.env.settings) }
        .padding(.top, 8)
    }

    @ViewBuilder private func paneView(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(model: model)
        case .shortcuts: ShortcutsPane(model: model)
        case .triggers: TriggersPane(model: model)
        case .privacy: PrivacyPane(model: model)
        case .storage: StoragePane(model: model)
        case .about: AboutPane()
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    let model: SettingsModel
    @State private var status: LoginItemStatus

    init(model: SettingsModel) {
        self.model = model
        _status = State(initialValue: model.env.login.status)
    }

    var body: some View {
        let presentation = LoginItemPresentation(status: status)
        Form {
            Toggle(isOn: Binding(
                get: { presentation.isOn },
                set: { on in
                    switch model.env.login.setEnabled(on) {
                    case .success(let new): status = new
                    case .failure(let error): model.env.report(error); status = model.env.login.status
                    }
                })
            ) { Text(SettingsString.launchAtLogin) }
            if let caption = presentation.caption { Text(caption).settingsCaption() }
            if presentation.showsLoginItemsButton {
                Button { model.env.openLoginItems() } label: { Text(SettingsString.openLoginItems) }
            }
            Toggle(isOn: model.binding(SettingKeys.screenshotsEnabled)) { Text(SettingsString.pickUpScreenshots) }
            Toggle(isOn: model.binding(SettingKeys.shelfEnabled)) { Text(SettingsString.shelf) }
            Picker(selection: model.binding(SettingKeys.shelfPlacement)) {
                ForEach(ShelfPlacement.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: { Text(SettingsString.shelfPlacement) }
            Toggle(isOn: model.binding(SettingKeys.shelfRevealOnEdgeHover)) { Text(SettingsString.revealAtEdge) }
                .disabled(!ShelfRevealRule.isEnabled(
                    shelfEnabled: model.value(SettingKeys.shelfEnabled), placement: model.value(SettingKeys.shelfPlacement)))
            Button { model.env.showSetupGuide() } label: { Text(SettingsString.showSetupGuide) }
        }
        .settingsPaneChrome()
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    let model: SettingsModel

    var body: some View {
        // Read-only until the recorder (FRD-005) lands; the stored chord is what the hotkey registers.
        Form {
            row(.shortcutOpenLibrary, SettingKeys.shortcutsOpenLibrary)
            row(.shortcutSaveClipboard, SettingKeys.shortcutsSaveClipboard)
            row(.shortcutToggleShelf, SettingKeys.shortcutsToggleShelf)
            Text(SettingsString.shortcutsFootnote).settingsCaption()
        }
        .settingsPaneChrome()
    }

    private func row(_ title: SettingsString, _ key: SettingKey<ChordBinding>) -> some View {
        LabeledContent {
            switch model.value(key) {
            case .chord(let chord): Text(chord.displayString)
            case .none: Text(SettingsString.shortcutNotSet).foregroundStyle(.secondary)
            }
        } label: { Text(title) }
    }
}

// MARK: - Triggers and Privacy

private struct PermissionRows: View {
    let model: SettingsModel

    var body: some View {
        ForEach(PermissionRow.current(probe: model.env.permissions)) { row in
            LabeledContent {
                HStack {
                    Text(row.status)
                    Button { model.env.permissions.openSystemSettings(row.kind) } label: {
                        Text(SettingsString.openSystemSettings)
                    }
                }
            } label: {
                VStack(alignment: .leading) {
                    Text(row.name)
                    Text(row.enables).settingsCaption()
                }
            }
        }
    }
}

private struct TriggersPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Toggle(isOn: model.binding(SettingKeys.triggersEnabled)) { Text(SettingsString.expandTriggers) }
            PermissionRows(model: model)
            Section {
                ForEach(model.value(SettingKeys.triggersExcludedApps).identifiers, id: \.self) { Text($0) }
            } header: { Text(SettingsString.excludedApps) } footer: { Text(SettingsString.excludedAppsHelp).settingsCaption() }
        }
        .settingsPaneChrome()
    }
}

private struct PrivacyPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.value(SettingKeys.privacyIgnoredApps).identifiers, id: \.self) { Text($0) }
            } header: { Text(SettingsString.ignoredApps) } footer: { Text(SettingsString.ignoredAppsHelp).settingsCaption() }
            Text(SettingsString.neverStored).settingsCaption()
            Text(SettingsString.noNetwork).settingsCaption()
            PermissionRows(model: model)
        }
        .settingsPaneChrome()
    }
}

// MARK: - Storage

private struct StoragePane: View {
    let model: SettingsModel
    @State private var usage: String?

    var body: some View {
        Form {
            Picker(selection: retentionBinding) {
                ForEach(RetentionPreset.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: { Text(SettingsString.keepHistoryFor) }
            Picker(selection: budgetBinding) {
                ForEach(ImageBudget.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: { Text(SettingsString.imageLimit) }
            Picker(selection: model.binding(SettingKeys.storageImageQuality)) {
                ForEach(ImageQuality.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: { Text(SettingsString.imageQuality) }
            Picker(selection: model.binding(SettingKeys.captureMode)) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: { Text(SettingsString.captureMode) }
            Text(usage ?? SettingsString.usageUnavailable.text).settingsCaption()
            Button { NSWorkspace.shared.open(model.env.dataFolder) } label: { Text(SettingsString.revealDataFolder) }
        }
        .settingsPaneChrome()
        .task { await loadUsage() }
    }

    private func loadUsage() async {
        guard case .success(let value) = await model.env.storage.usage() else { return }
        let bytes = ByteCountFormatter()
        usage = [
            "\(SettingsString.usageItems.text) \(value.totalItems)",
            "\(SettingsString.usageImages.text) \(bytes.string(fromByteCount: value.imageBytes))",
            "\(SettingsString.usageDatabase.text) \(bytes.string(fromByteCount: value.databaseBytes))",
        ].joined(separator: " · ")
    }

    /// A shorter period or a lower budget can delete items, so it asks first when the preview is above zero (FR-007-09);
    /// Cancel leaves the stored value, and the control snaps back.
    private var retentionBinding: Binding<RetentionPreset> {
        Binding(
            get: { model.value(SettingKeys.storageRetention) },
            set: { new in
                let old = model.env.settings.value(SettingKeys.storageRetention)
                Task { @MainActor in
                    var count = 0
                    if StorageChangeFlow.needsPreview(retention: new, from: old),
                        case .success(let preview) = await model.env.storage.retentionPreview(new)
                    {
                        count = preview.count
                    }
                    if case .confirm = StorageChangeFlow.after(previewCount: count),
                        !Self.confirm(.confirmShortenTitle, .confirmShorten, count)
                    { model.bump(); return }
                    model.env.settings.set(new, for: SettingKeys.storageRetention)
                    await sweep()
                }
            })
    }

    private var budgetBinding: Binding<ImageBudget> {
        Binding(
            get: { model.value(SettingKeys.storageImageBudget) },
            set: { new in
                let old = model.env.settings.value(SettingKeys.storageImageBudget)
                Task { @MainActor in
                    var count = 0
                    if StorageChangeFlow.needsPreview(budget: new, from: old),
                        case .success(let preview) = await model.env.storage.budgetPreview(new)
                    {
                        count = preview.count
                    }
                    if case .confirm = StorageChangeFlow.after(previewCount: count),
                        !Self.confirm(.confirmBudgetTitle, .confirmBudget, count)
                    { model.bump(); return }
                    model.env.settings.set(new, for: SettingKeys.storageImageBudget)
                    await sweep()
                }
            })
    }

    private func sweep() async {
        let settings = model.env.settings
        let result = await model.env.storage.sweep(
            settings.value(SettingKeys.storageRetention), settings.value(SettingKeys.storageImageBudget))
        if case .failure(let error) = result { model.env.report(error) }
        await loadUsage()
    }

    @MainActor private static func confirm(_ title: SettingsString, _ body: SettingsString, _ count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = title.text
        alert.informativeText = body.text([.count(count)])
        alert.addButton(withTitle: SettingsString.confirmShorten.text([.count(count)]))
        alert.addButton(withTitle: SettingsString.cancel.text)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        Form {
            Text(SettingsString.tagline)
            Text(SettingsString.version.text(
                version: info?["CFBundleShortVersionString"] as? String ?? "",
                build: info?["CFBundleVersion"] as? String ?? ""))
            Text(SettingsString.licenceLine).settingsCaption()
        }
        .settingsPaneChrome()
    }
}
