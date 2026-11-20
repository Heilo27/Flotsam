import AppKit
import FlotsamBase
import SwiftUI

/// The shared look of a pane (DESIGN section 3.3): a grouped form, 560 points wide, as tall as its content, but never
/// taller than the screen the window sits on (FR-008-03): a pane that would not fit scrolls instead of being cut off at
/// the window's bottom edge.
private struct PaneChrome: ViewModifier {
    static let width: CGFloat = 560
    /// Title bar, toolbar and the margin the window keeps from the screen edges.
    static let windowAllowance: CGFloat = 140
    static let fallbackScreenHeight: CGFloat = 800

    private var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? Self.fallbackScreenHeight
        return max(screen - Self.windowAllowance, 320)
    }

    func body(content: Content) -> some View {
        let form = content.formStyle(.grouped).frame(width: Self.width)
        ViewThatFits(in: .vertical) {
            form.scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            form
        }
        .frame(minHeight: 0, idealHeight: maxHeight, maxHeight: maxHeight)
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

/// The one look of an editable field outside a grouped form (DESIGN section 2.1): the text-field surface with the
/// control-edge border, so it reads as a field in light and dark; the accent ring takes over while it is active. The
/// Library search field, the shortcut recorder, the trigger field and the Add Clip editor all use this.
private struct FieldChrome: ViewModifier {
    let isActive: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background(Color(nsColor: .textBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(
                isActive ? Color.accentColor : Color.primary.opacity(0.35), lineWidth: isActive ? 2 : 1))
    }
}

extension View {
    func fieldChrome(isActive: Bool, cornerRadius: CGFloat = 6) -> some View {
        modifier(FieldChrome(isActive: isActive, cornerRadius: cornerRadius))
    }
}
