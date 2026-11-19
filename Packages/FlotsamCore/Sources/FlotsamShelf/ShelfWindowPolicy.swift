import FlotsamBase
import Foundation

/// The Shelf's window behaviour (FRD-006 FR-006-02, FR-006-08), as values with no AppKit so it is testable.
///
/// Revealing the Shelf never activates Flotsam: `Ordering` has no case that does. A sticky Shelf (hotkey, menu item)
/// becomes key; a transient one (drag, hover, menu-bar-icon drag) is ordered front and never becomes key.
public enum ShelfWindowPolicy {
    /// Borderless, non-activating, floating, all Spaces, over full-screen apps, out of window cycling; the user cannot
    /// resize or move it (FR-006-02, FR-006-05).
    public static let windowSpec = PanelWindowSpec(
        isNonActivating: true, isFloating: true, joinsAllSpaces: true, isFullScreenAuxiliary: true,
        ignoresWindowCycling: true, hidesOnDeactivate: false, isResizable: false, isMovableByBackground: false)

    /// How the panel is put on screen once its content is loaded.
    public enum Ordering: Sendable, Equatable {
        /// Make the panel key and order it front (still without activating the app).
        case keyAndFront
        /// Order it front without making it key: keyboard focus stays where it was.
        case frontWithoutKey
    }

    public static func ordering(for mode: ShelfRevealMode) -> Ordering {
        switch mode {
        case .sticky: .keyAndFront
        case .transient: .frontWithoutKey
        }
    }
}
