import FlotsamBase
import SwiftUI

/// Shortcuts (FR-008-05): one row per registry shortcut, showing the bound chord.
///
/// TODO(FRD-005): the recorder control, conflict detection and the clear button belong to FRD-005 (FR-005-01 to -04).
/// Until it lands the rows are read-only; `ShortcutRow` is the single place to swap in the recorder.
struct ShortcutsPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                ShortcutRow(label: .shortcutOpenLibrary, binding: model.value(SettingKeys.shortcutsOpenLibrary))
                ShortcutRow(label: .shortcutSaveClipboard, binding: model.value(SettingKeys.shortcutsSaveClipboard))
                ShortcutRow(label: .shortcutToggleShelf, binding: model.value(SettingKeys.shortcutsToggleShelf))
            } footer: {
                Text(.shortcutsFootnote).settingsCaption()
            }
        }
        .settingsPaneChrome()
    }
}

private struct ShortcutRow: View {
    let label: SettingsString
    let binding: ChordBinding

    var body: some View {
        LabeledContent {
            Text(verbatim: shown)
        } label: {
            Text(label)
        }
    }

    private var shown: String {
        switch binding {
        case .none: SettingsString.shortcutNotSet.text
        case .chord(let chord): chord.displayString
        }
    }
}
