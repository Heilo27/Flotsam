import AppKit
import FlotsamPayload

/// What the Shelf's content view reports about drags and the pointer (FR-006-12, FR-006-03). The controller owns every
/// decision; the view only forwards what AppKit tells it.
@MainActor
protocol ShelfDropDelegate: AnyObject {
    /// A drag entered or moved over the panel. Returns `.copy` when the Shelf takes it, `[]` when it refuses (the
    /// not-allowed cursor, FR-006-12).
    func shelfDragUpdated(_ info: any NSDraggingInfo) -> NSDragOperation
    /// The drag left the panel and is still going.
    func shelfDragExited()
    /// The drag session is over (refused, cancelled with Esc, or dropped anywhere), whether or not a mouse-up reached
    /// the global monitors.
    func shelfDragEnded()
    /// The drop happened. Returns whether the drop was taken; storing continues asynchronously.
    func shelfPerformDrop(_ info: any NSDraggingInfo) -> Bool
    /// The pointer entered or left the panel. Global monitors do not see events over the app's own windows, so the
    /// tracking area is what tells the reveal machine the pointer is on the Shelf or has left it (FR-006-03).
    func shelfPointerMoved()
}

/// The panel's content view: the blur background, a drag destination for the drop zone, and a tracking area for the
/// pointer. `draggingSource` of a drag that began in the Shelf is the Shelf's own `ShelfDragOut`, which the delegate refuses (a drag from a Library row is not the Shelf's own and is accepted by the usual rules).
final class ShelfDropView: NSVisualEffectView {
    weak var delegate: (any ShelfDropDelegate)?
    private var area: NSTrackingArea?
    /// The pointer was already inside the panel when it appeared. A window-server tracking area only knows the pointer is
    /// inside after it has seen it move in, so a panel that appears under a pointer that then leaves without ever
    /// having entered gets no `mouseExited`, and the reveal machine keeps hearing `.onShelf` (FR-006-47).
    private var assumeInside = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Every type clipboard capture honours; whether a particular drag is taken is `ShelfDropPlanner.acceptance`.
        registerForDraggedTypes(PasteboardTypes.honoured.map { NSPasteboard.PasteboardType($0) })
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") } // fatal-ok: AppKit-required initialiser; the view is built in code, never decoded

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if assumeInside { options.insert(.assumeInside) }
        let fresh = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(fresh)
        area = fresh
    }

    /// Tells the tracking area where the pointer is at the moment the panel appears (`true`) or that the panel is gone
    /// (`false`), so the first exit is reported (FR-006-47). Event-driven: no monitor and no timer.
    func assumePointerInside(_ inside: Bool) {
        guard inside != assumeInside else { return }
        assumeInside = inside
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { delegate?.shelfPointerMoved() }

    override func mouseExited(with event: NSEvent) {
        // The area knows the pointer is outside now; the next reveal sets the assumption afresh.
        assumeInside = false
        delegate?.shelfPointerMoved()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        delegate?.shelfDragUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        delegate?.shelfDragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { delegate?.shelfDragExited() }

    override func draggingEnded(_ sender: any NSDraggingInfo) { delegate?.shelfDragEnded() }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        delegate?.shelfPerformDrop(sender) ?? false
    }
}
