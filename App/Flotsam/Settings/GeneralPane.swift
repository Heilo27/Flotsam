import AppKit
import FlotsamBase
import SwiftUI

/// General (FR-008-04): Launch at Login and the setup guide, screenshot pickup, folder and import, and the Shelf, in one
/// grouped form with a header per group and each note directly under its own control. The Library and capture settings
/// have their own pane (`LibraryPane`, FR-008-33) so neither pane is taller than a laptop screen.
struct GeneralPane: View {
    let model: SettingsModel
    @State private var loginStatus: LoginItemStatus

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
                    trailing { Button { model.env.openLoginItems() } label: { Text(.openLoginItems) } }
                }
                // A labelled row, like the folder row: a button alone in a row reads as a stray control (FR-008-04).
                LabeledContent {
                    Button { model.env.showSetupGuide() } label: { Text(.showSetupGuide) }
                } label: {
                    Text(.setupGuide)
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
                trailing { Button { model.env.importRecentScreenshots() } label: { Text(.importRecentScreenshots) } }
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
        }
        .settingsPaneChrome()
        .onAppear { loginStatus = model.env.login.status }
    }

    /// A button that is alone in its row sits on the trailing edge, the edge the switches and the other buttons use (FR-008-04).
    private func trailing<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { Spacer(minLength: 0); content() }
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
