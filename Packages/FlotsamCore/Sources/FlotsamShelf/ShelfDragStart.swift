import FlotsamBase
import FlotsamPayload
import Foundation

/// What can stop a Shelf drag-out from starting, or from supplying a card's data, and which error each is (FR-006-11).
/// Pure: the app layer gathers the facts (is there a window and an event, did the OS take each pasteboard writer) and
/// asks here. AppKit exposes a failure only before the session starts or while it asks for data, never after the
/// session has begun, so these are the places `SHF-OS-001` is decided; a session that ends with no operation is a
/// user cancel (`ShelfDragEnd`).
public enum ShelfDragStart {
    /// Why the OS could not start the drag or supply a card's data. Each is `SHF-OS-001`.
    public enum OSFailure: Sendable, Equatable {
        /// There was nothing to start a drag from (an empty drag list).
        case noCard
        /// The dragged view is not in a window.
        case noWindow
        /// There is no mouse event to start the drag from.
        case noEvent
        /// The OS refused a pasteboard item's data provider.
        case providerRejected
        /// The OS asked for a type the card does not hold, so no data could be supplied.
        case noRepresentation
    }

    /// The one place `SHF-OS-001` is constructed for the drag-out.
    public static func osError(_ failure: OSFailure) -> FlotsamError {
        switch failure {
        case .noCard: FlotsamError(.shfOs001, "No card to drag")
        case .noWindow: FlotsamError(.shfOs001, "Drag source view has no window")
        case .noEvent: FlotsamError(.shfOs001, "Drag has no mouse event")
        case .providerRejected: FlotsamError(.shfOs001, "Pasteboard refused a drag item")
        case .noRepresentation: FlotsamError(.shfOs001, "Drag asked for a type the card does not hold")
        }
    }

    /// The one place `LIB-DAT-001` is constructed for a drag with nothing left to provide. The card id is logged only
    /// when a single card was dragged.
    public static func nothingLeftToDrag(cards: [UUID]) -> FlotsamError {
        let context: [LogKey: LogSafeValue] = cards.count == 1 ? [.itemId: .id(cards[0])] : [:]
        return FlotsamError(.libDat001, "Nothing left to drag", context: context)
    }

    // MARK: Before the session

    /// Checks the plan a moment before the session starts. Without a window or an event the drag cannot start
    /// (`SHF-OS-001`). A file member that no longer exists or cannot be read is skipped, as the planner skips a missing
    /// member; when that leaves nothing, the drag does not start (`LIB-DAT-001`).
    public static func preflight(
        _ plan: ShelfDragPlan,
        hasWindow: Bool,
        hasEvent: Bool,
        files: any FileSystemPort,
        isReadable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
    ) -> FlotsamResult<ShelfDragPlan> {
        guard hasWindow else { return .failure(osError(.noWindow)) }
        guard hasEvent else { return .failure(osError(.noEvent)) }
        let items = plan.items.filter { item in
            guard let data = fileURLData(of: item) else { return true }
            guard let url = PasteboardTypes.fileURL(from: data) else { return false }
            return files.fileExists(at: url) && isReadable(url.path)
        }
        guard !items.isEmpty else { return .failure(nothingLeftToDrag(cards: plan.draggedItemIds)) }
        let remaining = Set(items.map(\.itemId))
        return .success(ShelfDragPlan(items: items, draggedItemIds: plan.draggedItemIds.filter(remaining.contains)))
    }

    /// The URL data of an item that is exactly one file-URL representation (a file or one bundle member).
    private static func fileURLData(of item: ShelfDragItem) -> Data? {
        guard case .representations(let representations) = item.payload,
              representations.count == 1, representations[0].uti == PasteboardTypes.fileURL else { return nil }
        return representations[0].data
    }

    // MARK: Building the session

    /// What the OS did with one planned item when the app tried to make its pasteboard writer.
    public enum WriterOutcome: Sendable, Equatable {
        case written
        /// `setDataProvider` returned false: an OS failure.
        case providerRejected
        /// `NSImage(data:)` returned nil: the card has no usable image data, which is "nothing to drag" (FR-006-11).
        case imageUnreadable
    }

    public enum Launch: Sendable, Equatable {
        /// Start the session with the written items. `report` is an `SHF-OS-001` for items the OS refused while others
        /// were written: the drag still goes ahead with the rest.
        case start(draggedItemIds: [UUID], report: FlotsamError?)
        /// No session starts.
        case fail(FlotsamError)
    }

    /// - Parameter outcomes: one per `plan.items`, in order.
    public static func launch(_ plan: ShelfDragPlan, outcomes: [WriterOutcome]) -> Launch {
        let written = Set(zip(plan.items, outcomes).filter { $0.1 == .written }.map(\.0.itemId))
        let rejected = outcomes.contains(.providerRejected)
        guard !written.isEmpty else {
            return .fail(rejected ? osError(.providerRejected) : nothingLeftToDrag(cards: plan.draggedItemIds))
        }
        return .start(
            draggedItemIds: plan.draggedItemIds.filter(written.contains),
            report: rejected ? osError(.providerRejected) : nil)
    }
}
