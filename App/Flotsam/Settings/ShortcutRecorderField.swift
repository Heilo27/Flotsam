import FlotsamBase
import SwiftUI

/// The one shortcut recorder control (FR-005-04, FR-005-09, FR-008-05): a field that shows the chord as keycaps, starts
/// recording when clicked, and carries its own clear button. Settings' Shortcuts rows and the item editor both use it,
/// so the two can never drift apart. The recording itself is `ShortcutRecorderModel`; this is only the look and the
/// two actions. A rejected chord's message shows under the field.
struct ShortcutRecorderField: View {
    let chord: Chord?
    let recorder: ShortcutRecorderModel
    /// Where clearing is not allowed (`openLibrary`, FR-005-01) this is false and the clear button never shows.
    let allowClear: Bool
    let startRecording: () -> Void
    let clear: () -> Void
    /// A fixed border-to-border width, for a form whose fields must share one (the item editor). nil sizes to the content.
    var fieldWidth: CGFloat?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                field
                if allowClear, chord != nil, !recorder.isRecording {
                    Button(action: clear) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(AccessoryGlyphButtonStyle())
                    .help(SettingsString.shortcutClear.text)
                    .accessibilityLabel(SettingsString.shortcutClear.text)
                }
            }
            if let message = recorder.errorMessage {
                Text(verbatim: message).settingsCaption().foregroundStyle(.red)
            }
        }
    }

    private var field: some View {
        Button(action: startRecording) {
            HStack(spacing: 3) {
                if recorder.isRecording {
                    Text(.shortcutRecording).foregroundStyle(.secondary)
                } else if let chord {
                    ForEach(Array(chord.keycaps.enumerated()), id: \.offset) { _, cap in
                        Keycap(key: cap, font: .system(size: 12), minWidth: 20)
                            .frame(minHeight: 20)
                    }
                } else {
                    Text(.shortcutRecord).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 150, minHeight: FieldMetric.height, maxHeight: FieldMetric.height, alignment: .leading)
            .padding(.horizontal, 6)
            .frame(width: fieldWidth, alignment: .leading)
            .fieldChrome(isActive: focused || recorder.isRecording)
            .contentShape(RoundedRectangle(cornerRadius: DesignToken.Radius.control))
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .accessibilityLabel(SettingsString.shortcutRecord.text)
        .accessibilityValue(chord?.displayString ?? SettingsString.shortcutNotSet.text)
    }
}
