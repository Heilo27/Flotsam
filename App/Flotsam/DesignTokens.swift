import AppKit
import SwiftUI

/// The app's visual constants (DESIGN section 2.4): one corner-radius scale and one selection tone, so the Library, the
/// Shelf and Settings never disagree about what "selected" or "rounded" means.
enum DesignToken {
    /// Corner radii, DESIGN section 2.4. Nothing in the app draws a radius that is not on this scale.
    enum Radius {
        static let panel: CGFloat = 16
        static let popover: CGFloat = 12
        static let card: CGFloat = 10
        static let row: CGFloat = 8
        static let control: CGFloat = 6
        static let chip: CGFloat = 6
    }

    /// The one selection fill (DESIGN section 2.2, 4): the system accent, opaque, so the contrast of the label on it does not
    /// depend on what is behind the panel. It is the accent mixed 60% toward white in light and 50% toward black in dark: the same
    /// hue in both appearances, and the primary label (and `onSelectionSecondary`) clear 4.5:1 on it in both.
    static let selectionFill = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let accent = NSColor.controlAccentColor
        return accent.blended(withFraction: dark ? 0.5 : 0.6, of: dark ? .black : .white) ?? accent
    })
    /// Secondary text on a selected row or pill: the primary label at reduced strength, never `.secondary` (which fades into the fill).
    static let onSelectionSecondary = Color.primary.opacity(0.82)
    /// The hover and keyboard-cursor wash on a row that is not selected.
    static let cursorFill = Color.primary.opacity(0.08)
}
