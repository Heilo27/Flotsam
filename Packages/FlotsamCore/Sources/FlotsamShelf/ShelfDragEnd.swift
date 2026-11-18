import FlotsamBase
import Foundation

/// What the end of a drag-out session means (FR-006-11). AppKit always begins a session that starts, and reports one that
/// ends with no operation the same way whatever the cause, so an ended session with no operation is a user cancel (Esc,
/// or dropped on nothing). A drag the OS cannot start or supply is reported before or while it runs (`ShelfDragStart`).
public enum ShelfDragEnd: Sendable, Equatable {
    /// A drop target accepted the drag: count one paste per card and hide a transient Shelf.
    case accepted(cards: [UUID])
    /// Esc or a drop on nothing: nothing changes and nothing is shown.
    case userCancelled
    /// Nothing was being dragged, so there is nothing to account for or report.
    case none

    /// - Parameters:
    ///   - accepted: the session ended with an operation other than none.
    ///   - cards: the cards the session was dragging (those that got a writer), in on-screen order.
    public static func resolve(accepted: Bool, cards: [UUID]) -> ShelfDragEnd {
        guard !cards.isEmpty else { return .none }
        if accepted { return .accepted(cards: cards) }
        return .userCancelled
    }
}
