import Foundation
import FlotsamBase

/// Panel geometry that does not need AppKit (FR-003-03, DESIGN section 3.1), so the placement rule is testable.
public enum LibraryLayout {
    public static let minimumSize = PanelSize(width: 560, height: 360)

    /// A list row is 44 pt tall (FR-003-07, FR-003-21, DESIGN section 3.1).
    public static let listRowHeight: CGFloat = 44
    /// The lead slot of a list row: a 32 pt thumbnail or kind icon (FR-003-07, DESIGN section 3.1).
    public static let listLeadSize: CGFloat = 32

    /// The remembered size, raised to the minimum (FR-003-03).
    public static func clamped(_ size: PanelSize) -> PanelSize {
        PanelSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
    }

    /// Where the panel opens: centred horizontally on `visibleFrame` (the pointer's screen, menu bar and Dock
    /// excluded), top edge one third of the way down it (FR-003-03). Coordinates are AppKit's, origin bottom left.
    /// A size larger than the screen is cut to the screen so the panel never opens off it.
    public static func frame(in visibleFrame: CGRect, size: PanelSize) -> CGRect {
        let fitted = clamped(size)
        let width = min(fitted.width, visibleFrame.width)
        let height = min(fitted.height, visibleFrame.height)
        let top = visibleFrame.maxY - visibleFrame.height / 3
        let originY = max(visibleFrame.minY, top - height)
        return CGRect(x: visibleFrame.midX - width / 2, y: originY, width: width, height: height)
    }
}
