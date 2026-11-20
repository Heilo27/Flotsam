import FlotsamBase
import SwiftUI

/// Library (FR-008-33): how the Library opens and looks, Restore Library Defaults, and what is captured into it, in one
/// grouped form. These were the General pane's Library and Capture sections until General grew taller than a laptop
/// screen (TASK-529 round 3).
struct LibraryPane: View {
    let model: SettingsModel
    @State private var confirmingReset = false

    var body: some View {
        Form {
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
        }
        .settingsPaneChrome()
        .confirmationDialog(Text(.resetLibraryTitle), isPresented: $confirmingReset) {
            Button { model.env.settings.resetToDefaults() } label: { Text(.resetLibraryConfirm) }
            Button(role: .cancel) {} label: { Text(.cancel) }
        } message: {
            Text(.resetLibraryMessage)
        }
    }
}
