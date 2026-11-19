import FlotsamBase
import FlotsamPayload
import FlotsamStorage
import Foundation

/// One card being dragged out, with its loaded content (FR-006-10). The app layer loads the content (`content(of:)`)
/// for the cards `ShelfModel.covered(by:)` returns and hands them over in that order.
public struct ShelfDragCandidate: Sendable, Equatable {
    public let itemId: UUID
    public let content: ItemContent
    /// A secure card's text, revealed by the app layer at mouse-down after the owner authenticated (FR-006-21). Nil for
    /// every other card, and for a secure card whose authentication failed: it then provides nothing.
    public let revealedSecureText: String?

    public init(itemId: UUID, content: ItemContent, revealedSecureText: String? = nil) {
        self.itemId = itemId
        self.content = content
        self.revealedSecureText = revealedSecureText
    }
}

/// What one drag-pasteboard item carries.
public enum ShelfDragPayload: Sendable, Equatable {
    /// Written as they are: text and its stored representations, or one file URL.
    case representations([PasteboardRepresentation])
    /// An image: the app layer builds an `NSImage` from the bytes (FR-006-10 "image data through `NSImage`").
    case image(PasteboardRepresentation)
}

/// One drag-pasteboard item, and the card it came from.
public struct ShelfDragItem: Sendable, Equatable {
    public let itemId: UUID
    public let payload: ShelfDragPayload

    public init(itemId: UUID, payload: ShelfDragPayload) {
        self.itemId = itemId
        self.payload = payload
    }
}

/// What a drag-out puts on the drag pasteboard.
public struct ShelfDragPlan: Sendable, Equatable {
    /// The pasteboard items, in on-screen order of their cards; a bundle contributes one per existing member.
    public let items: [ShelfDragItem]

    /// The cards that contributed at least one item, in on-screen order. On an accepted drag each gets one paste
    /// counted (FR-006-11), a bundle once however many members it has.
    public let draggedItemIds: [UUID]

    /// The number of cards the plan provides for (cards, not pasteboard items). It is an upper bound on what is
    /// dragged: the app skips a card none of whose items it can write (an image `NSImage` cannot read), so the drag
    /// image's badge and the `shelf.dragOut` count (FR-006-10, FR-006-18) use the cards that got a writer, not this.
    public var cardCount: Int { draggedItemIds.count }
}

/// Decides what a drag-out provides (FR-006-10, FR-006-11). Pure: no AppKit, no pasteboard, no database. It follows the
/// paste rules (FRD-003 FR-003-15), which live on `ItemContent`, and differs only where FR-006-10 says: a bundle is one
/// pasteboard item per member, nothing is marked own-write, and the general pasteboard is never touched.
public enum ShelfDragPlanner {
    /// - Parameter candidates: the dragged cards in on-screen order.
    /// - Returns: the plan; `SHF-OS-001` when there is nothing to drag; `LIB-DAT-001` when no card has anything left to
    ///   provide (every member of a file card gone, so the drag does not start).
    public static func plan(_ candidates: [ShelfDragCandidate], files: any FileSystemPort) -> FlotsamResult<ShelfDragPlan> {
        guard !candidates.isEmpty else {
            return .failure(ShelfDragStart.osError(.noCard))
        }
        var items: [ShelfDragItem] = []
        var contributing: [UUID] = []
        for candidate in candidates {
            let payloads = payloads(of: candidate, files: files)
            guard !payloads.isEmpty else { continue }
            items += payloads.map { ShelfDragItem(itemId: candidate.itemId, payload: $0) }
            contributing.append(candidate.itemId)
        }
        guard !items.isEmpty else {
            return .failure(ShelfDragStart.nothingLeftToDrag(cards: candidates.map(\.itemId)))
        }
        return .success(ShelfDragPlan(items: items, draggedItemIds: contributing))
    }

    private static func payloads(of candidate: ShelfDragCandidate, files: any FileSystemPort) -> [ShelfDragPayload] {
        let content = candidate.content
        // A secure card drags only what the owner revealed, as plain text with `ConcealedType`; unrevealed it gives
        // nothing, so a stored secure item can never reach a drag without the authentication.
        if content.isSecure {
            return candidate.revealedSecureText.map { [.representations(SecureClip.pasteboardRepresentations(revealing: $0))] } ?? []
        }
        if content.kind.referencesFiles {
            return content.existingMemberURLs(files: files).map { .representations([ItemContent.fileURLRepresentation(for: $0)]) }
        }
        if content.kind.isImage {
            let best = PasteboardTypes.imagePriority.lazy.compactMap { uti in content.representations.first { $0.uti == uti } }.first
            return best.map { [.image($0)] } ?? []
        }
        let representations = content.storedRepresentations
        return representations.isEmpty ? [] : [.representations(representations)]
    }
}
