import AppKit
import FlotsamPayload

/// What the Shelf's content view reports about drags and the pointer (FR-006-12, FR-006-03). The controller owns every
/// decision; the view only forwards what AppKit tells it.
@MainActor
protocol ShelfDropDelegate: AnyObject {
    /// A drag entered or moved over the panel. Returns `.copy` when the Shelf takes it, `[]` when it refuses (the
    /// not-allowed cursor, FR-006-12).
    func shelfDragUpdated(_ info: any NSDraggingInfo) -> NSDragOperation
    func shelfDragExited()
    /// The drop happened. Returns whether the drop was taken; storing continues asynchronously.
    func shelfPerformDrop(_ info: any NSDraggingInfo) -> Bool
    /// The pointer entered or left the panel. Global monitors do not see events over the app's own windows, so the
    /// tracking area is what tells the reveal machine the pointer is on the Shelf or has left it (FR-006-03).
    func shelfPointerMoved()
}

/// The panel's content view: the blur background, a drag destination for the drop zone, and a tracking area for the
/// pointer. `draggingSource` of a drag that began in the Shelf is a `ShelfDragOut`, which the delegate refuses.
final class ShelfDropView: NSVisualEffectView {
    weak var delegate: (any ShelfDropDelegate)?
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Every type clipboard capture honours; whether a particular drag is taken is `ShelfDropPlanner.acceptance`.
        registerForDraggedTypes(PasteboardTypes.honoured.map { NSPasteboard.PasteboardType($0) })
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") } // fatal-ok: AppKit-required initialiser; the view is built in code, never decoded

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let fresh = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(fresh)
        area = fresh
    }

    override func mouseEntered(with event: NSEvent) { delegate?.shelfPointerMoved() }
    override func mouseExited(with event: NSEvent) { delegate?.shelfPointerMoved() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        delegate?.shelfDragUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        delegate?.shelfDragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { delegate?.shelfDragExited() }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        delegate?.shelfPerformDrop(sender) ?? false
    }
}
