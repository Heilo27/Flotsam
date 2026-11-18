import FlotsamBase
import Foundation

/// What the end of a drag-out session means (FR-006-11). AppKit reports a session that ends with no operation the same
/// way whether the user cancelled it (Esc, or dropped on nothing) or the system aborted it; the only difference it
/// leaves is whether the session ever began. A session that ends without having begun was aborted by the system.
public enum ShelfDragEnd: Sendable, Equatable {
    /// A drop target accepted the drag: count one paste per card and hide a transient Shelf.
    case accepted(cards: [UUID])
    /// Esc or a drop on nothing: nothing changes and nothing is shown.
    case userCancelled
    /// The system aborted the drag: nothing changes, and the error is reported (`SHF-OS-001`, HUD).
    case aborted(FlotsamError)
    /// Nothing was being dragged, so there is nothing to account for or report.
    case none

    /// - Parameters:
    ///   - accepted: the session ended with an operation other than none.
    ///   - sessionBegan: the session's begin callback ran before it ended.
    ///   - cards: the cards the session was dragging (those that got a writer), in on-screen order.
    public static func resolve(accepted: Bool, sessionBegan: Bool, cards: [UUID]) -> ShelfDragEnd {
        guard !cards.isEmpty else { return .none }
        if accepted { return .accepted(cards: cards) }
        if sessionBegan { return .userCancelled }
        return .aborted(FlotsamError(.shfOs001, "Drag session aborted by the system"))
    }
}
