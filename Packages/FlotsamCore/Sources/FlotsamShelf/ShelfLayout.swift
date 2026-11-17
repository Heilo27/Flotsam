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

    // MARK: Panel (FR-006-05)

    public static let panelWidth: CGFloat = 280
    public static let minimumHeight: CGFloat = 160
    /// Left, right and menu-bar panels stay this far short of the visible height.
    public static let heightMargin: CGFloat = 40
    public static let bottomHeight: CGFloat = 140
    public static let bottomMaxWidthFraction: CGFloat = 0.8

    // MARK: Cards and sections (FR-006-06, FR-006-07)

    public static let cardHeight: CGFloat = 64
    public static let bottomCardWidth: CGFloat = 112
    public static let cardSpacing: CGFloat = 4
    public static let sectionHeaderHeight: CGFloat = 24
    public static let contentPadding: CGFloat = 8

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

    /// True for the placements that lay the cards in one horizontal row.
    public static func isHorizontal(_ placement: ShelfPlacement) -> Bool { placement == .bottomEdge }

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
        case .bottomEdge:
            let length = screenFrame.width * edgeZoneLengthFraction
            return CGRect(x: screenFrame.midX - length / 2, y: screenFrame.minY, width: length, height: thickness)
        case .menuBar:
            return nil
        }
    }

    /// The index of the first screen whose edge zone holds `point`, or `nil`. A point on the far border of the
    /// zone counts as inside, because the pointer's position on the last pixel of a screen is its maxX or maxY.
    public static func screenIndex(of point: CGPoint, placement: ShelfPlacement, screens: [CGRect]) -> Int? {
        screens.firstIndex { screen in
            guard let zone = edgeZone(for: placement, in: screen) else { return false }
            return point.x >= zone.minX && point.x <= zone.maxX && point.y >= zone.minY && point.y <= zone.maxY
        }
    }

    // MARK: Frame

    /// The height of the content for a vertical list: cards, their gaps, one header per non-empty section and padding.
    /// An empty Shelf (the empty state) is as tall as the minimum.
    public static func contentHeight(pinnedCount: Int, recentCount: Int) -> CGFloat {
        let sections = [pinnedCount, recentCount].filter { $0 > 0 }
        guard !sections.isEmpty else { return minimumHeight }
        let cards = CGFloat(pinnedCount + recentCount)
        let gaps = CGFloat(max(pinnedCount + recentCount - sections.count, 0)) * cardSpacing
        return contentPadding * 2 + CGFloat(sections.count) * sectionHeaderHeight + cards * cardHeight + gaps
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
        case .bottomEdge:
            let width = min(max(contentExtent, panelWidth), visibleFrame.width * bottomMaxWidthFraction)
            let height = min(bottomHeight, visibleFrame.height)
            return CGRect(x: visibleFrame.midX - width / 2, y: visibleFrame.minY, width: width, height: height)
        case .menuBar:
            let width = min(panelWidth, visibleFrame.width)
            let anchorX = menuBarIcon?.midX ?? visibleFrame.maxX
            let top = min(menuBarIcon?.minY ?? visibleFrame.maxY, visibleFrame.maxY)
            let height = min(verticalHeight(contentExtent, in: visibleFrame), max(top - visibleFrame.minY, 0))
            let originX = min(max(anchorX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
            return CGRect(x: originX, y: top - height, width: width, height: height)
        }
    }

    /// The card size for a placement (FR-006-07): 64 pt tall across the panel, or 112 pt wide in the bottom strip.
    public static func cardSize(for placement: ShelfPlacement) -> CGSize {
        if isHorizontal(placement) {
            return CGSize(width: bottomCardWidth, height: bottomHeight - contentPadding * 2)
        }
        return CGSize(width: panelWidth - contentPadding * 2, height: cardHeight)
    }

    private static func verticalHeight(_ contentHeight: CGFloat, in visibleFrame: CGRect) -> CGFloat {
        let cap = max(visibleFrame.height - heightMargin, minimumHeight)
        return min(max(contentHeight, minimumHeight), min(cap, visibleFrame.height))
    }
}
