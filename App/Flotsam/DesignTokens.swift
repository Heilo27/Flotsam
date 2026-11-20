import AppKit
import FlotsamBase
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

    /// The selected result row's fill (DESIGN section 2.2, 4): the system accent at selection weight (hill-climb r5: muted
    /// toward grey so it no longer out-shouts the search field), opaque, so the contrast of the label on it does not depend on
    /// what is behind the panel. It is the one place the accent fills a surface in the Library: buttons and toggles use the
    /// same hue. Light: the accent mixed 30% toward a light grey, then 65% toward white. Dark: the accent mixed 35% toward a
    /// mid-dark grey, then toward black by the least amount (from 30%, to 70%) that leaves the secondary label
    /// (`onSelectionSecondary`, the weaker of the two) 4.5:1 on it, so a light accent (yellow, orange, green) darkens only as
    /// far as the text needs. Measured for all eight system accents in DESIGN 2.2: both labels clear 4.5:1, Yellow included.
    static let selectionFill = Color(nsColor: NSColor(name: nil) { appearance in
        let accent = NSColor.controlAccentColor
        guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else {
            let muted = accent.blended(withFraction: 0.3, of: NSColor(white: 0.8, alpha: 1)) ?? accent
            return muted.blended(withFraction: 0.65, of: .white) ?? muted
        }
        let base = accent.blended(withFraction: 0.35, of: NSColor(white: 0.3, alpha: 1)) ?? accent
        var fraction: CGFloat = 0.3
        // 0.69 is the dark primary label (white at 0.85) times `onSelectionSecondary`'s 0.82, rounded down.
        while fraction < 0.7, let fill = base.blended(withFraction: fraction, of: .black),
              contrast(of: NSColor.white.withAlphaComponent(0.69), over: fill) < 4.5 {
            fraction += 0.05
        }
        return base.blended(withFraction: fraction, of: .black) ?? base
    })
    /// The sidebar's selected row: a neutral wash with the primary label, so the sidebar never competes with the one accent fill
    /// on the selected result row (DESIGN section 3.1).
    static let sidebarSelection = Color.primary.opacity(0.12)
    /// Secondary text on a selected row or pill: the primary label at reduced strength, never `.secondary` (which fades into the fill).
    static let onSelectionSecondary = Color.primary.opacity(0.82)
    /// The hover and keyboard-cursor wash on a row that is not selected.
    static let cursorFill = Color.primary.opacity(0.08)

    /// The one end fade (DESIGN section 2.2, hill-climb r5): a scroller's last edge dissolves over this height before the
    /// footer or the panel edge. One whole row (24 pt) plus 8 pt, so no glyph can sit half-cut at the edge. The Library
    /// sidebar, the Library grid and the Shelf all use it, with a bottom content margin of the same height so the last row
    /// scrolls clear of the fade.
    static let endFadeHeight: CGFloat = 36

    /// The type cue of a clip kind (DESIGN section 2.1, hill-climb r5): the colour of a Shelf card's top edge and of its kind
    /// icon, so a column of cards reads by type before it is read by text. System colours, so they follow appearance and the
    /// user's contrast settings. Decoration only (WCAG 1.4.1): the icon and the card's text always say the type too.
    static func typeCue(for kind: ItemKind) -> Color {
        switch kind {
        case .text: .gray
        case .richText: .indigo
        case .link: .blue
        case .color: .pink
        case .phone: .green
        case .email: .teal
        case .image: .purple
        case .file: .orange
        case .folder: .brown
        case .bundle: .yellow
        case .screenshot: .cyan
        }
    }

    /// WCAG 2.x contrast of `text` (alpha respected) drawn over the opaque `fill`.
    private static func contrast(of text: NSColor, over fill: NSColor) -> CGFloat {
        guard let fillRGB = fill.usingColorSpace(.sRGB), let textRGB = text.usingColorSpace(.sRGB) else { return 21 }
        let alpha = textRGB.alphaComponent
        func mixed(_ t: CGFloat, _ f: CGFloat) -> CGFloat { t * alpha + f * (1 - alpha) }
        let shown = luminance(mixed(textRGB.redComponent, fillRGB.redComponent), mixed(textRGB.greenComponent, fillRGB.greenComponent), mixed(textRGB.blueComponent, fillRGB.blueComponent))
        let behind = luminance(fillRGB.redComponent, fillRGB.greenComponent, fillRGB.blueComponent)
        return (max(shown, behind) + 0.05) / (min(shown, behind) + 0.05)
    }

    private static func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

/// The one hairline between two regions (DESIGN section 2.4, hill-climb r5): the system separator colour at one device
/// pixel, never a heavier custom line.
struct Hairline: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    @Environment(\.displayScale) private var scale

    init(_ axis: Axis = .horizontal) { self.axis = axis }

    var body: some View {
        let thickness = 1 / max(scale, 1)
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: axis == .vertical ? thickness : nil, height: axis == .horizontal ? thickness : nil)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Fades the last `height` points to clear (0: no fade). Pair it with a bottom content margin of the same height
    /// (`DesignToken.endFadeHeight`), so the final row can be scrolled out of the fade and the fade reaches 0 opacity
    /// at the edge (nothing partly visible).
    func fadingBottomEdge(_ height: CGFloat) -> some View {
        mask(
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: height)
            })
    }
}
