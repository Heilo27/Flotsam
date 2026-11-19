import AppKit

/// Presents the system share picker for what was dropped on the Shelf's share zone (FR-006-42). The picker and the
/// services behind it (AirDrop, Messages, Mail) carry the content, at the person's action; Flotsam sends nothing
/// itself and holds no network code (A1). It holds the items, and the data providers behind them, until the picker
/// reports it is done, because the drag session that built them has ended by then.
@MainActor
final class ShelfSharePicker: NSObject, NSSharingServicePickerDelegate {
    private var picker: NSSharingServicePicker?
    private var shared: ShelfShareItems?
    private var finished: (@MainActor () -> Void)?

    /// Shows the picker for `shared`, anchored on `rect` of `view`. `finished` runs once, when the person has chosen a
    /// service or dismissed the picker.
    func present(
        _ shared: ShelfShareItems, from view: NSView, rect: NSRect, preferredEdge: NSRectEdge,
        finished: @escaping @MainActor () -> Void
    ) {
        self.shared = shared
        self.finished = finished
        let picker = NSSharingServicePicker(items: shared.items)
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    /// AppKit calls its delegates on the main thread; the protocol is not main-actor isolated, so the hop is asserted.
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            let done = finished
            picker = nil
            shared = nil
            finished = nil
            done?()
        }
    }
}
