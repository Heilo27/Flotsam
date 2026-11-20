import SwiftUI

/// The one keycap (DESIGN section 3.1, FR-005-04): a key name or symbol on a small rounded chip. The Library footer's
/// hints and the shortcut recorder both draw their keys with this, so a key never looks different in two places. The
/// leading hint of the footer is the accented one (`emphasized`), the same fill as the selected result row.
struct Keycap: View {
    let key: String
    var font: Font = .caption
    var emphasized = false
    /// Narrow caps (a lone modifier symbol) keep a square footprint instead of collapsing to the glyph's width.
    var minWidth: CGFloat = 0

    var body: some View {
        Text(verbatim: key)
            .font(font.weight(emphasized ? .semibold : .regular))
            .padding(.horizontal, 4)
            .frame(minWidth: minWidth)
            .background(
                emphasized ? DesignToken.selectionFill : DesignToken.cursorFill,
                in: RoundedRectangle(cornerRadius: DesignToken.Radius.chip))
    }
}
