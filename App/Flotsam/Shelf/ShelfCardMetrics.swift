import AppKit
import FlotsamShelf

/// The height of a Shelf card in the vertical placements (FR-006-07, hill-climb r3). A text card is measured, not guessed:
/// its text is laid out at the width and font the card draws it in, so a card is its real lines tall and never leaves blank
/// lines under two or three lines of text. The other kinds keep the standard height.
@MainActor
enum ShelfCardMetrics {
    /// The text column's width: the card, less its 8 pt side padding and the 14 pt kind icon with its 6 pt gap.
    private static var textWidth: CGFloat { ShelfLayout.panelWidth - ShelfLayout.contentPadding * 2 - 8 * 2 - 14 - 6 }
    private static let font = NSFont.preferredFont(forTextStyle: .callout)

    static var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) }

    /// How a text card shows its text: the whole lines that fit (never a half-cut last line) and whether the text goes on
    /// past them, in which case the card fades its last line (FR-006-07, hill-climb r4).
    struct TextFit {
        let height: CGFloat
        let shownLines: Int
        let isClamped: Bool
    }

    /// nil for a card that does not draw its text as lines (image, colour, file and the other kinds).
    static func textFit(of card: ShelfCardPresentation) -> TextFit? {
        guard case .kindIcon = card.visual, let text = card.text else { return nil }
        let lineHeight = lineHeight
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let lines = Int((bounds.height / lineHeight).rounded(.up))
        let shown = min(max(lines, 1), ShelfLayout.maxTextLines(lineHeight: lineHeight))
        return TextFit(
            height: ShelfLayout.cardHeight(forLineCount: lines, lineHeight: lineHeight), shownLines: shown, isClamped: lines > shown)
    }

    static func height(of card: ShelfCardPresentation) -> CGFloat {
        textFit(of: card)?.height ?? card.verticalHeight
    }
}

/// Which type pills fit in the Shelf's search header (FR-006-22, hill-climb r3). A pill is never drawn cut off: the pills that
/// fit are shown whole and the rest sit in a "More" menu, so nothing reads as clipped and nothing is unreachable.
@MainActor
enum ShelfPillMetrics {
    static let spacing: CGFloat = 6
    private static let horizontalPadding: CGFloat = 10
    private static let font = NSFont.preferredFont(forTextStyle: .caption1)
    /// The chevron and its gap on the More pill.
    private static let moreChevronWidth: CGFloat = 14

    static func pillWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width) + horizontalPadding * 2
    }

    /// How many of `titles` (All first, then each type) are drawn whole in `available` points; the rest go in the More menu.
    /// All titles fit: `titles.count`. Otherwise the count that leaves room for the More pill, never fewer than one.
    static func visibleCount(titles: [String], moreTitle: String, available: CGFloat) -> Int {
        let widths = titles.map(pillWidth)
        let total = widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
        if total <= available { return titles.count }
        let more = pillWidth(moreTitle) + moreChevronWidth
        var used = more
        var count = 0
        for width in widths {
            guard used + width + spacing <= available else { break }
            used += width + spacing
            count += 1
        }
        return max(count, 1)
    }
}
