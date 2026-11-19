import AppKit
import FlotsamBase
import FlotsamShortcuts
import SwiftUI

/// Shortcuts (FR-008-05): one row per global shortcut with the recorder (FR-005-04). A recorded chord is written to its
/// setting; `AppContainer` watches those settings and binds the chord (one registration path, FR-005-01).
struct ShortcutsPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                ShortcutRow(
                    model: model, label: .shortcutOpenLibrary, id: .openLibrary, key: SettingKeys.shortcutsOpenLibrary,
                    allowClear: false)
                ShortcutRow(
                    model: model, label: .shortcutSaveClipboard, id: .saveClipboard, key: SettingKeys.shortcutsSaveClipboard,
                    allowClear: true)
                ShortcutRow(
                    model: model, label: .shortcutToggleShelf, id: .toggleShelf, key: SettingKeys.shortcutsToggleShelf,
                    allowClear: true)
                ShortcutRow(
                    model: model, label: .shortcutPasteQueue, id: .pasteQueue, key: SettingKeys.shortcutsPasteQueue,
                    allowClear: true)
            } footer: {
                Text(.shortcutsFootnote).settingsCaption()
            }
        }
        .settingsPaneChrome()
    }
}

private struct ShortcutRow: View {
    let model: SettingsModel
    let label: SettingsString
    let id: ShortcutID
    let key: SettingKey<ChordBinding>
    /// `openLibrary` can be changed but not cleared (FR-005-01).
    let allowClear: Bool
    @State private var recorder = ShortcutRecorderModel()

    var body: some View {
        let binding = model.value(key)
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    if recorder.isRecording {
                        Text(.shortcutRecording).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: shown(binding))
                        Button(SettingsString.shortcutRecord.text) { startRecording() }
                        if allowClear, binding != .none {
                            Button(SettingsString.shortcutClear.text) { model.binding(key).wrappedValue = .none }
                        }
                    }
                }
                if let message = recorder.errorMessage {
                    Text(verbatim: message).settingsCaption().foregroundStyle(.red)
                }
            }
        } label: {
            Text(label)
        }
        // The recorder must not outlive the pane or the window's focus: its hotkey suspension would stick.
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in recorder.stop() }
    }

    private func startRecording() {
        recorder.start(registry: model.env.shortcuts, id: id, allowClear: allowClear) { newBinding in
            model.binding(key).wrappedValue = newBinding
        }
    }

    private func shown(_ binding: ChordBinding) -> String {
        switch binding {
        case .none: SettingsString.shortcutNotSet.text
        case .chord(let chord): chord.displayString
        }
    }
}
