import FlotsamBase
import SwiftUI

/// The shared look of a pane (DESIGN section 3.3): a grouped form, 560 points wide, as tall as its content.
private struct PaneChrome: ViewModifier {
    static let width: CGFloat = 560

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    func settingsPaneChrome() -> some View { modifier(PaneChrome()) }

    /// Secondary explanatory text under a control.
    func settingsCaption() -> some View {
        font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A control's label with its explanatory note directly under it, as one row, so a note can never drift away from the
/// control it explains (a separate caption row sits under a divider, apart from its control).
struct SettingLabel: View {
    let title: SettingsString
    let note: String?

    init(_ title: SettingsString, note: String? = nil) {
        self.title = title
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let note { Text(verbatim: note).settingsCaption() }
        }
    }
}
