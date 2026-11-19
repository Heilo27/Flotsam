import Foundation
import FlotsamBase

/// Where the pointer is, as the reveal machine hears it (FR-006-03, FR-006-04). The panel controller feeds it the
/// pointer position and the facts it owns (panel frame, screens, whether the hover monitor is installed); the decision
/// itself is here so it runs on plain values in tests.
public enum ShelfPointerClassifier {
    /// `.onShelf` while the Shelf is visible and the pointer is inside its pointer area (`ShelfLayout.pointerArea`);
    /// `.menuBarIcon` over the icon with the menu-bar placement; `.edgeZone` in the placement's zone on the screen
    /// that holds the pointer; otherwise `.away`.
    /// - Parameters:
    ///   - panelFrame: the panel's final frame (or where it slides to), not its mid-animation frame.
    ///   - screenFrame: the frame of the screen the panel is on, `nil` when unknown.
    ///   - hoverMonitored: the global mouse-moved monitor is installed (`shelf.revealOnEdgeHover` on).
    public static func region(
        at point: CGPoint, placement: ShelfPlacement, isVisible: Bool, panelFrame: CGRect, screenFrame: CGRect?,
        hoverMonitored: Bool, screens: [CGRect], menuBarIcon: CGRect?
    ) -> ShelfRevealMachine.Pointer {
        if isVisible {
            let area = screenFrame.map {
                ShelfLayout.pointerArea(for: placement, panelFrame: panelFrame, screenFrame: $0, menuBarStripCounts: hoverMonitored)
            } ?? panelFrame
            if ShelfLayout.contains(area, point) { return .onShelf }
        }
        if placement == .menuBar, let icon = menuBarIcon, icon.contains(point) {
            return .menuBarIcon(screen: ShelfLayout.screenIndex(containing: point, in: screens) ?? 0)
        }
        if let screen = ShelfLayout.screenIndex(of: point, placement: placement, screens: screens) {
            return .edgeZone(screen: screen)
        }
        return .away
    }
}
