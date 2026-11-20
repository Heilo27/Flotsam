import Foundation
import FlotsamBase

/// A display as the Library places itself: its full frame (pointer tests) and its visible frame (menu bar and Dock
/// excluded). Coordinates are AppKit's, origin bottom left.
public struct LibraryScreen: Sendable, Equatable {
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Panel geometry that does not need AppKit (FR-003-03, DESIGN section 3.1), so the placement rule is testable.
public enum LibraryLayout {
    public static let minimumSize = PanelSize(width: 560, height: 360)
    /// The Compact layout's minimum: the sidebar and a list a row can still read in (FR-003-03).
    public static let compactMinimumSize = PanelSize(width: 480, height: 400)

    /// The smallest the panel may be in `layout` (FR-003-03). The one place that picks between the two minimums.
    public static func minimumSize(for layout: LibraryLayoutMode) -> PanelSize {
        switch layout {
        case .standard: minimumSize
        case .compact: compactMinimumSize
        }
    }

    /// A list row is 44 pt tall (FR-003-07, FR-003-21, DESIGN section 3.1).
    public static let listRowHeight: CGFloat = 44
    /// The trailing room a hovered list row keeps for its hover strip (three 22 pt targets, 2 pt gaps, the capsule's padding)
    /// plus 8 pt of air, so the title truncates well before the strip instead of running under or touching it (FR-003-38,
    /// hill-climb r5).
    public static let hoverStripReserve: CGFloat = 94
    /// The least gap between two list rows and the margin above the first (FR-003-05).
    public static let listRowSpacing: CGFloat = 2
    public static let listTopMargin: CGFloat = 4

    /// The list's scroll geometry for a viewport `available` points tall (FR-003-05): a whole number of rows, so the edge
    /// above the footer falls between two rows and never slices one. The rows take the leftover height as extra gap
    /// (under a row's height), `rowSpacing` is that gap, and `viewport` is exactly `rows` rows plus the top margin; the
    /// scroll content ends one gap below the last row, so the far end of the scroll lands on a row boundary too.
    public struct ListFit: Sendable, Equatable {
        public let rows: Int
        public let rowSpacing: CGFloat
        public let viewport: CGFloat
    }

    public static func listFit(fitting available: CGFloat) -> ListFit {
        let usable = max(available - listTopMargin, 0)
        let rows = max(Int((usable / (listRowHeight + listRowSpacing)).rounded(.down)), 1)
        let spacing = max(usable / CGFloat(rows) - listRowHeight, 0)
        return ListFit(rows: rows, rowSpacing: spacing, viewport: listTopMargin + CGFloat(rows) * (listRowHeight + spacing))
    }

    /// The lead slot of a list row: a 32 pt thumbnail or kind icon (FR-003-07, DESIGN section 3.1).
    public static let listLeadSize: CGFloat = 32

    /// The remembered size, raised to the minimum (FR-003-03).
    public static func clamped(_ size: PanelSize, layout: LibraryLayoutMode = .standard) -> PanelSize {
        let floor = minimumSize(for: layout)
        return PanelSize(width: max(size.width, floor.width), height: max(size.height, floor.height))
    }

    /// The visible frame used when the system reports no screen at all.
    public static let fallbackVisibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// The screen the panel opens on: the one whose frame contains the pointer (a full-screen app's display included),
    /// else the main screen, else the first (FR-003-03).
    public static func screen(containing pointer: CGPoint, in screens: [LibraryScreen], main: LibraryScreen?) -> LibraryScreen? {
        screens.first { $0.frame.contains(pointer) } ?? main ?? screens.first
    }

    /// Where the panel opens: centred horizontally on `visibleFrame` (the pointer's screen, menu bar and Dock
    /// excluded), top edge one third of the way down it (FR-003-03). Coordinates are AppKit's, origin bottom left.
    /// A size larger than the screen is cut to the screen so the panel never opens off it.
    public static func frame(in visibleFrame: CGRect, size: PanelSize, layout: LibraryLayoutMode = .standard) -> CGRect {
        let fitted = clamped(size, layout: layout)
        let width = min(fitted.width, visibleFrame.width)
        let height = min(fitted.height, visibleFrame.height)
        let top = visibleFrame.maxY - visibleFrame.height / 3
        let originY = max(visibleFrame.minY, top - height)
        return CGRect(x: visibleFrame.midX - width / 2, y: originY, width: width, height: height)
    }
}

/// Which columns the Library draws (FR-003-06, FR-003-14). The sidebar and the results column are in every layout; the
/// only decision is where the preview goes, so the view draws from this and never compares layouts itself.
public struct LibraryColumns: Sendable, Equatable {
    public enum PreviewPlacement: Sendable, Equatable {
        /// Preview closed.
        case hidden
        /// Standard: a pane to the right of the results.
        case rightPane
        /// Compact: the preview takes the results column's place, the sidebar stays.
        case replacesList
    }

    public let preview: PreviewPlacement

    /// The list is drawn unless the preview has taken its place.
    public var showsList: Bool { preview != .replacesList }

    /// `hasPreviewableRow` is true when the results column holds a loaded list with exactly one row selected. In
    /// Compact the preview takes the results column's place only then: an empty history, a search with no match and a
    /// failed load put their message (with Retry) in that column (FR-003-17, FR-003-20), so the preview gives way to it
    /// and comes back when a row is selected again (FR-003-14). Standard keeps its own pane, so it is not affected.
    public static func resolve(layout: LibraryLayoutMode, previewOpen: Bool, hasPreviewableRow: Bool) -> LibraryColumns {
        guard previewOpen else { return LibraryColumns(preview: .hidden) }
        switch layout {
        case .standard: return LibraryColumns(preview: .rightPane)
        case .compact: return LibraryColumns(preview: hasPreviewableRow ? .replacesList : .hidden)
        }
    }
}
