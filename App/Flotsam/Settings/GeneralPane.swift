import AppKit
import FlotsamBase
import SwiftUI

/// General (FR-008-04): Launch at Login, screenshot pickup, folder and import, the Shelf, the Library, capture, and the
/// setup guide, in one grouped form with a header per group and each note directly under its own control.
struct GeneralPane: View {
    let model: SettingsModel
    @State private var loginStatus: LoginItemStatus
    @State private var confirmingReset = false

    init(model: SettingsModel) {
        self.model = model
        _loginStatus = State(initialValue: model.env.login.status)
    }

    var body: some View {
        let login = LoginItemPresentation(status: loginStatus)
        let shelfEnabled = model.value(SettingKeys.shelfEnabled)
        let placement = model.value(SettingKeys.shelfPlacement)
        Form {
            Section {
                Toggle(isOn: Binding(get: { login.isOn }, set: { setLogin($0) })) {
                    SettingLabel(.launchAtLogin, note: login.caption?.text)
                }
                if login.showsLoginItemsButton {
                    Button { model.env.openLoginItems() } label: { Text(.openLoginItems) }
                }
            } header: {
                Text(.sectionSystem)
            }
            Section {
                Toggle(isOn: model.binding(SettingKeys.screenshotsEnabled)) { Text(.pickUpScreenshots) }
                LabeledContent {
                    HStack {
                        Button { chooseFolder() } label: { Text(.chooseFolder) }
                        Button { model.env.settings.set(.none, for: SettingKeys.screenshotsFolderOverride) } label: {
                            Text(.useSystemDefault)
                        }
                        .disabled(model.value(SettingKeys.screenshotsFolderOverride) == .none)
                    }
                } label: {
                    SettingLabel(.screenshotFolder, note: folderName)
                }
                // FR-002-12: always available, including while pickup is off, so never disabled.
                Button { model.env.importRecentScreenshots() } label: { Text(.importRecentScreenshots) }
            } header: {
                Text(.sectionScreenshots)
            }
            Section {
                Toggle(isOn: model.binding(SettingKeys.shelfEnabled)) { Text(.shelf) }
                Picker(selection: model.binding(SettingKeys.shelfPlacement)) {
                    ForEach(ShelfPlacement.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { Text(.shelfPlacement) }
                .disabled(!shelfEnabled)
                Toggle(isOn: model.binding(SettingKeys.shelfRevealOnEdgeHover)) {
                    SettingLabel(.revealAtEdge, note: SettingsString.revealAtEdgeHelp.text)
                }
                .disabled(!ShelfRevealRule.isEnabled(shelfEnabled: shelfEnabled, placement: placement))
                Toggle(isOn: model.binding(SettingKeys.shelfEdgeBar)) {
                    SettingLabel(.edgeBar, note: SettingsString.edgeBarHelp.text)
                }
                .disabled(!ShelfRevealRule.isEnabled(shelfEnabled: shelfEnabled, placement: placement))
            } header: {
                Text(.sectionShelf)
            }
            Section {
                Picker(selection: model.binding(SettingKeys.libraryLayout)) {
                    ForEach(LibraryLayoutMode.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { SettingLabel(.libraryLayout, note: SettingsString.libraryLayoutHelp.text) }
                Picker(selection: model.binding(SettingKeys.libraryBackground)) {
                    ForEach(LibraryBackground.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { Text(.libraryBackground) }
                Picker(selection: model.binding(SettingKeys.libraryPreviewPreset)) {
                    ForEach(LibraryPreviewPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { SettingLabel(.previewPreset, note: SettingsString.previewPresetHelp.text) }
                Picker(selection: model.binding(SettingKeys.libraryDisplay)) {
                    ForEach(LibraryDisplay.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { Text(.libraryDisplay) }
                Toggle(isOn: model.binding(SettingKeys.libraryCloseAfterPaste)) {
                    SettingLabel(.closeAfterPaste, note: SettingsString.closeAfterPasteHelp.text)
                }
                Toggle(isOn: model.binding(SettingKeys.libraryResumeOnReopen)) {
                    SettingLabel(.resumeOnReopen, note: SettingsString.resumeOnReopenHelp.text)
                }
                Button { confirmingReset = true } label: { Text(.resetLibraryDefaults) }
            } header: {
                Text(.sectionLibrary)
            }
            Section {
                Toggle(isOn: model.binding(SettingKeys.captureAutoBundle)) {
                    SettingLabel(.autoBundle, note: SettingsString.autoBundleHelp.text)
                }
                Toggle(isOn: model.binding(SettingKeys.captureCue)) {
                    SettingLabel(.captureCue, note: SettingsString.captureCueHelp.text)
                }
            } header: {
                Text(.sectionCapture)
            }
            Section {
                Button { model.env.showSetupGuide() } label: { Text(.showSetupGuide) }
            } header: {
                Text(.sectionSetup)
            }
        }
        .settingsPaneChrome()
        .confirmationDialog(Text(.resetLibraryTitle), isPresented: $confirmingReset) {
            Button { model.env.settings.resetToDefaults() } label: { Text(.resetLibraryConfirm) }
            Button(role: .cancel) {} label: { Text(.cancel) }
        } message: {
            Text(.resetLibraryMessage)
        }
        .onAppear { loginStatus = model.env.login.status }
    }

    /// The effective folder name: the override's folder, or "System default".
    private var folderName: String {
        model.value(SettingKeys.screenshotsFolderOverride).resolvedURL?.lastPathComponent
            ?? SettingsString.folderSystemDefault.text
    }

    /// Launch at Login reads macOS each time; a refused change reports `SET-OS-001` and the switch shows the real state.
    private func setLogin(_ on: Bool) {
        switch model.env.login.setEnabled(on) {
        case .success(let status): loginStatus = status
        case .failure(let error):
            loginStatus = model.env.login.status
            model.env.report(error)
        }
    }

    /// "Choose…" (FR-008-10): a folder panel; an unusable folder is `SET-VAL-001` and the previous value stays.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = SettingsString.chooseFolder.text
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch FolderOverride.choosing(url) {
        case .success(let override): model.env.settings.set(override, for: SettingKeys.screenshotsFolderOverride)
        case .failure(let error): model.env.report(error)
        }
    }
}
