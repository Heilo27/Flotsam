import Foundation
import FlotsamBase

/// How the panel changes state: sliding from its edge, or a fade when Reduce Motion is on (FR-006-05).
public struct ShelfTransition: Sendable, Equatable {
    public enum Style: Sendable, Equatable { case slide, fade }
    public let style: Style
    public let showDuration: TimeInterval
    public let hideDuration: TimeInterval
}

/// Shelf geometry that does not need AppKit (FRD-006 FR-006-03, FR-006-05, FR-006-07), so the rules are testable.
/// Coordinates are AppKit's: origin bottom left, y grows upward. This is the one home of the Shelf's constants
/// (FRD-006 section 4); the reveal timings live in `ShelfRevealMachine`.
public enum ShelfLayout {
    // MARK: Hot zone (FR-006-03)

    /// The edge zone is this thick, in points.
    public static let edgeZoneThickness: CGFloat = 4
    /// The edge zone covers this fraction of the edge's length, centred.
    public static let edgeZoneLengthFraction: CGFloat = 0.6
    /// How long a dropped card stays highlighted (FR-006-15). The 1.5 s hold is `ShelfRevealMachine.dropHold`.
    public static let dropHighlightDuration: TimeInterval = 0.6

    // MARK: Collapsed edge bar (FR-006-37)

    /// The collapsed bar is this thick and this long, in points, centred on its edge of the visible frame.
    public static let edgeBarThickness: CGFloat = 6
    public static let edgeBarLength: CGFloat = 96

    // MARK: Panel (FR-006-05)

    public static let panelWidth: CGFloat = 280
    public static let minimumHeight: CGFloat = 160
    /// Left, right and menu-bar panels stay this far short of the visible height.
    public static let heightMargin: CGFloat = 40
    public static let bottomHeight: CGFloat = 140
    public static let bottomMaxWidthFraction: CGFloat = 0.8

    // MARK: Cards and sections (FR-006-06, FR-006-07)

    /// A card is a header row (source icon, app name, age) over a content area (hill-climb r1, TASK-529): 96 pt tall in the
    /// vertical placements, 144 pt wide in the horizontal ones.
    public static let cardHeight: CGFloat = 96
    public static let bottomCardWidth: CGFloat = 144
    public static let cardSpacing: CGFloat = 4
    public static let sectionHeaderHeight: CGFloat = 24
    public static let contentPadding: CGFloat = 8
    /// A text card shows the first three lines, at most 120 characters (FR-006-07).
    public static let cardTextLineLimit = 3
    public static let cardTextCharacterLimit = 120
    /// How much stored text is read for a card: far more than three lines of 120 characters need, so text that is
    /// mostly blank lines still yields its three lines, and a huge text item is never read in full.
    public static let cardTextReadLimit = 1_000
    /// Each section lists at most this many cards (FR-006-06).
    public static let sectionLimit = 20
    /// While a search or type filter is active each section lists up to one page of matches (FR-006-22), so a search
    /// reaches past the 20 newest cards. One page is the query layer's own size (FR-007-18).
    public static let resultLimit = LibraryQuery.pageSize

    // MARK: Search header (FR-006-22)

    /// The search field and type pills a sticky Shelf shows above its cards: one row in the horizontal placements (the
    /// 140 pt strip keeps its height, its cards give the row up), two rows (field, then pills) in the vertical ones.
    /// A transient Shelf never takes key and shows no header (FR-006-08).
    public static let searchRowHeight: CGFloat = 32
    public static func searchHeaderHeight(for placement: ShelfPlacement) -> CGFloat {
        isHorizontal(placement) ? searchRowHeight : searchRowHeight * 2
    }

    // MARK: Share zone (FR-006-42)

    /// The share zone's thickness: a strip along the bottom of a vertical panel, along the trailing edge of a horizontal
    /// one. It exists only while a clip drag is over the panel.
    public static let shareZoneThickness: CGFloat = 64

    /// The share zone in the panel's own coordinates (origin bottom left, like the rest of this file). The view draws the
    /// zone on the same edge with the same thickness, so what is drawn is what takes the drop.
    public static func shareZone(for placement: ShelfPlacement, in size: CGSize) -> CGRect {
        if isHorizontal(placement) {
            return CGRect(x: size.width - shareZoneThickness, y: 0, width: shareZoneThickness, height: size.height)
        }
        return CGRect(x: 0, y: 0, width: size.width, height: shareZoneThickness)
    }

    // MARK: Motion (FR-006-05)

    public static let slideInDuration: TimeInterval = 0.150
    public static let slideOutDuration: TimeInterval = 0.120
    public static let fadeDuration: TimeInterval = 0.100

    public static func transition(reduceMotion: Bool) -> ShelfTransition {
        reduceMotion
            ? ShelfTransition(style: .fade, showDuration: fadeDuration, hideDuration: fadeDuration)
            : ShelfTransition(style: .slide, showDuration: slideInDuration, hideDuration: slideOutDuration)
    }

    // MARK: Hot zone

    /// True for the placements that lay the cards in one horizontal row (FR-006-07): the bottom strip and the top-centre
    /// row hung from the menu bar. They share one height, one width rule and one card size.
    public static func isHorizontal(_ placement: ShelfPlacement) -> Bool { placement == .bottomEdge || placement == .topCenter }

    /// The strip of `screenFrame` (the whole screen, not the visible frame, because the pointer rests at the physical
    /// edge) that reveals the Shelf: 4 pt thick over the middle 60 % of the edge. `nil` for the menu-bar placement,
    /// which has no edge zone (FR-006-03).
    public static func edgeZone(for placement: ShelfPlacement, in screenFrame: CGRect) -> CGRect? {
        let thickness = edgeZoneThickness
        switch placement {
        case .rightEdge, .leftEdge:
            let length = screenFrame.height * edgeZoneLengthFraction
            let originY = screenFrame.midY - length / 2
            let originX = placement == .rightEdge ? screenFrame.maxX - thickness : screenFrame.minX
            return CGRect(x: originX, y: originY, width: thickness, height: length)
        case .bottomEdge, .topCenter:
            let length = screenFrame.width * edgeZoneLengthFraction
            let originY = placement == .topCenter ? screenFrame.maxY - thickness : screenFrame.minY
            return CGRect(x: screenFrame.midX - length / 2, y: originY, width: length, height: thickness)
        case .menuBar:
            return nil
        }
    }

    /// The collapsed bar (FR-006-37): a small pill on the placement's edge of `visibleFrame`, centred along it, so it sits
    /// where the Shelf slides from and never covers the Dock or the menu bar. `nil` for the menu-bar placement, which has
    /// no edge.
    public static func edgeBar(for placement: ShelfPlacement, in visibleFrame: CGRect) -> CGRect? {
        let thickness = edgeBarThickness
        switch placement {
        case .rightEdge, .leftEdge:
            let length = min(edgeBarLength, visibleFrame.height)
            let originX = placement == .rightEdge ? visibleFrame.maxX - thickness : visibleFrame.minX
            return CGRect(x: originX, y: visibleFrame.midY - length / 2, width: thickness, height: length)
        case .bottomEdge, .topCenter:
            let length = min(edgeBarLength, visibleFrame.width)
            let originY = placement == .topCenter ? visibleFrame.maxY - thickness : visibleFrame.minY
            return CGRect(x: visibleFrame.midX - length / 2, y: originY, width: length, height: thickness)
        case .menuBar:
            return nil
        }
    }

    /// The index of the screen whose edge zone holds `point`, or `nil`. The screen is the one `screenIndex(containing:in:)`
    /// names, so a point on a seam between two screens is never offered the zone of the screen it just left.
    public static func screenIndex(of point: CGPoint, placement: ShelfPlacement, screens: [CGRect]) -> Int? {
        guard let index = screenIndex(containing: point, in: screens),
            let zone = edgeZone(for: placement, in: screens[index]), contains(zone, point)
        else { return nil }
        return index
    }

    /// The one answer to "which screen is this point on" (the reveal's screen, the icon's screen, the edge zone's
    /// screen). Containment is half-open, so the seam column or row between two screens belongs to exactly one of
    /// them (the one whose min edge it is). The pointer's position on the physical last column or row of the desktop is
    /// the screen's maxX or maxY, which no screen contains half-open: that point falls back to the first screen that
    /// holds it with its borders, so the top row of a screen with nothing above it still resolves to that screen.
    public static func screenIndex(containing point: CGPoint, in screens: [CGRect]) -> Int? {
        screens.firstIndex { $0.contains(point) } ?? screens.firstIndex { contains($0, point) }
    }

    // MARK: Frame

    /// The height of the content for a vertical list: cards, their gaps, one header per non-empty section and padding.
    /// An empty Shelf (the empty state) is as tall as the minimum.
    /// `headerHeight` is the search header of a sticky Shelf (0 for a transient one).
    public static func contentHeight(pinnedCount: Int, recentCount: Int, headerHeight: CGFloat = 0) -> CGFloat {
        let sections = [pinnedCount, recentCount].filter { $0 > 0 }
        guard !sections.isEmpty else { return minimumHeight }
        let cards = CGFloat(pinnedCount + recentCount)
        let gaps = CGFloat(max(pinnedCount + recentCount - sections.count, 0)) * cardSpacing
        return contentPadding * 2 + headerHeight + CGFloat(sections.count) * sectionHeaderHeight + cards * cardHeight + gaps
    }

    /// The width of the content for the bottom strip: one card per item in one row, padding either side. An empty
    /// Shelf is as wide as a vertical panel.
    public static func contentWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return panelWidth }
        return contentPadding * 2 + CGFloat(itemCount) * bottomCardWidth + CGFloat(itemCount - 1) * cardSpacing
    }

    /// The panel frame (FR-006-05) inside `visibleFrame`, the revealed screen's frame with the menu bar and Dock
    /// excluded, so the Dock is never covered. `contentExtent` is the content height for the vertical placements and
    /// the content width for the bottom one. `menuBarIcon` is the status item's frame and is used only by `.menuBar`;
    /// without it the panel hangs from the top right corner.
    public static func frame(
        for placement: ShelfPlacement,
        in visibleFrame: CGRect,
        contentExtent: CGFloat,
        menuBarIcon: CGRect? = nil
    ) -> CGRect {
        switch placement {
        case .rightEdge, .leftEdge:
            let width = min(panelWidth, visibleFrame.width)
            let height = verticalHeight(contentExtent, in: visibleFrame)
            let originX = placement == .rightEdge ? visibleFrame.maxX - width : visibleFrame.minX
            return CGRect(x: originX, y: visibleFrame.midY - height / 2, width: width, height: height)
        case .bottomEdge, .topCenter:
            let width = min(max(contentExtent, panelWidth), visibleFrame.width * bottomMaxWidthFraction)
            let height = min(bottomHeight, visibleFrame.height)
            // The top-centre row hangs from the top of the visible frame, which is the bottom edge of the menu bar.
            let originY = placement == .topCenter ? visibleFrame.maxY - height : visibleFrame.minY
            return CGRect(x: visibleFrame.midX - width / 2, y: originY, width: width, height: height)
        case .menuBar:
            let width = min(panelWidth, visibleFrame.width)
            let anchorX = menuBarIcon?.midX ?? visibleFrame.maxX
            let top = min(menuBarIcon?.minY ?? visibleFrame.maxY, visibleFrame.maxY)
            let height = min(verticalHeight(contentExtent, in: visibleFrame), max(top - visibleFrame.minY, 0))
            let originX = min(max(anchorX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
            return CGRect(x: originX, y: top - height, width: width, height: height)
        }
    }

    /// The card size for a placement (FR-006-07): 96 pt tall across the panel, or 144 pt wide in the bottom strip.
    /// In the horizontal placements a sticky Shelf's cards are as much shorter as its search row is tall (`showsSearch`).
    public static func cardSize(for placement: ShelfPlacement, showsSearch: Bool = false) -> CGSize {
        if isHorizontal(placement) {
            let header = showsSearch ? searchHeaderHeight(for: placement) : 0
            return CGSize(width: bottomCardWidth, height: bottomHeight - contentPadding * 2 - header)
        }
        return CGSize(width: panelWidth - contentPadding * 2, height: cardHeight)
    }

    /// Where a slide starts and ends (FR-006-05): `frame` moved out past its own edge of `visibleFrame`. The top-centre
    /// row slides down from, and back up under, the menu bar.
    public static func offscreenFrame(_ frame: CGRect, placement: ShelfPlacement, in visibleFrame: CGRect) -> CGRect {
        var moved = frame
        switch placement {
        case .rightEdge: moved.origin.x = visibleFrame.maxX
        case .leftEdge: moved.origin.x = visibleFrame.minX - frame.width
        case .bottomEdge: moved.origin.y = visibleFrame.minY - frame.height
        case .menuBar, .topCenter: moved.origin.y = visibleFrame.maxY
        }
        return moved
    }

    /// The area in which the pointer counts as being on a visible Shelf (FR-006-04): the panel, and for the top-centre
    /// row, while `menuBarStripCounts`, also the strip between the panel and the physical top of the screen, which is
    /// the menu bar. With hover reveal on, the pointer that revealed the row rests at that top edge, so without the
    /// strip it would count as having left the Shelf and the row would hide 600 ms after it appeared. The strip counts
    /// only while the mouse-moved monitor is installed (hover on): without it nothing reports a pointer moving
    /// sideways inside the strip, so the leave would never be seen and the Shelf would stay (TASK-557 class).
    public static func pointerArea(
        for placement: ShelfPlacement, panelFrame: CGRect, screenFrame: CGRect, menuBarStripCounts: Bool
    ) -> CGRect {
        guard placement == .topCenter, menuBarStripCounts, screenFrame.maxY > panelFrame.maxY else { return panelFrame }
        return CGRect(x: panelFrame.minX, y: panelFrame.minY, width: panelFrame.width, height: screenFrame.maxY - panelFrame.minY)
    }

    /// True when `point` is inside `area`, borders included: the pointer on the last pixel of a screen sits at its
    /// maxX or maxY, which `CGRect.contains` would call outside. For the panel and its pointer area only; which screen
    /// a point is on goes through `screenIndex(containing:in:)`. An empty area contains nothing.
    public static func contains(_ area: CGRect, _ point: CGPoint) -> Bool {
        guard !area.isEmpty else { return false }
        return point.x >= area.minX && point.x <= area.maxX && point.y >= area.minY && point.y <= area.maxY
    }

    private static func verticalHeight(_ contentHeight: CGFloat, in visibleFrame: CGRect) -> CGFloat {
        let cap = max(visibleFrame.height - heightMargin, minimumHeight)
        return min(max(contentHeight, minimumHeight), min(cap, visibleFrame.height))
    }
}
