import AppKit
import FlotsamBase
import FlotsamShortcuts
import SwiftUI

/// Shortcuts (FR-008-05): one row per global shortcut with the recorder (FR-005-04). A recorded chord is written to its
/// setting; `AppContainer` watches those settings and binds the chord (one registration path, FR-005-01).
struct ShortcutsPane: View {
    let model: SettingsModel

    /// A row is named by its menu entry, so the menu and this pane cannot disagree about the same command (Rule 9).
    private func menuLabel(_ key: String) -> String { FlotsamStrings.text(forKey: key) ?? key }

    var body: some View {
        Form {
            Section {
                ShortcutRow(
                    model: model, label: menuLabel("ui.menu.openLibrary"), id: .openLibrary, key: SettingKeys.shortcutsOpenLibrary,
                    allowClear: false)
                ShortcutRow(
                    model: model, label: menuLabel("ui.menu.saveClipboard"), id: .saveClipboard, key: SettingKeys.shortcutsSaveClipboard,
                    allowClear: true)
                ShortcutRow(
                    model: model, label: menuLabel("ui.menu.addClip"), id: .addClip, key: SettingKeys.shortcutsAddClip,
                    allowClear: true)
                ShortcutRow(
                    model: model, label: menuLabel("ui.menu.toggleShelf"), id: .toggleShelf, key: SettingKeys.shortcutsToggleShelf,
                    allowClear: true)
                ShortcutRow(
                    model: model, label: SettingsString.shortcutPasteQueue.text, id: .pasteQueue, key: SettingKeys.shortcutsPasteQueue,
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
    let label: String
    let id: ShortcutID
    let key: SettingKey<ChordBinding>
    /// `openLibrary` can be changed but not cleared (FR-005-01).
    let allowClear: Bool
    @State private var recorder = ShortcutRecorderModel()

    var body: some View {
        let binding = model.value(key)
        LabeledContent {
            ShortcutRecorderField(
                chord: chord(of: binding), recorder: recorder, allowClear: allowClear, startRecording: startRecording,
                clear: { model.binding(key).wrappedValue = .none })
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

    private func chord(of binding: ChordBinding) -> Chord? {
        switch binding {
        case .none: nil
        case .chord(let chord): chord
        }
    }
}
