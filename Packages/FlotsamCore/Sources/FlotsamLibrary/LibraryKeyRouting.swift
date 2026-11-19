import Foundation

/// Where a Library-panel key goes (FR-003-08, FR-004 overlays): the one decision the panel controller used to make inline.
/// The controller reads the key and the panel state, asks `route`, and only dispatches the answer. Pure, so the order
/// of the checks (overlay first, then the key map, then the search field) is pinned by tests instead of by the App
/// target, which has no test target.
public enum LibraryKeyRouting {
    public enum Action: Sendable, Equatable {
        /// An Organize overlay is open and owns the keyboard: hand the stroke to it. When the overlay does not consume
        /// it, the key still goes to the overlay's own text field, never to the Library's key map.
        case overlay
        /// The Library owns the key: run the command and consume the key.
        case library(LibraryCommand)
        /// The Library does not own the key: leave it for the search field (the standard ⌘C included).
        case passToField
    }

    /// `overlayIsOpen` comes before the key map, so an overlay swallows Esc, Return and ⌘C meant for its own fields.
    /// `context` carries the search-field state (empty, selection) and the view mode the key map needs.
    /// Accessibility trust is not an input: the key map picks the same command either way, and the copy-only fallback
    /// belongs to the paste step (`PasteService`, FR-003-15), after the command is dispatched.
    public static func route(_ stroke: LibraryKeyStroke, overlayIsOpen: Bool, context: LibraryKeyMap.Context) -> Action {
        if overlayIsOpen { return .overlay }
        guard let command = LibraryKeyMap.command(for: stroke, in: context) else { return .passToField }
        return .library(command)
    }
}
