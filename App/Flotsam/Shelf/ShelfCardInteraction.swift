import AppKit
import FlotsamBase
import SwiftUI

/// The mouse behaviour of one Shelf card (FR-006-09, FR-006-10): a click selects, a double-click pastes, and a drag past
/// a few points starts a drag-out. SwiftUI's tap and drag gestures cannot start an AppKit drag session, so this is an
/// AppKit view laid over the card.
///
/// Right-click and control-click fall through (`hitTest` returns nil for them) so the card's own SwiftUI `.contextMenu`
/// still opens. The panel never becomes key while transient, so the first click must act (`acceptsFirstMouse`).
struct ShelfCardInteraction: NSViewRepresentable {
    let onClick: @MainActor (ChordModifiers) -> Void
    let onDoubleClick: @MainActor () -> Void
    /// Mouse-down: read what a drag from this card would need.
    let prepareDrag: @MainActor () -> Void
    /// The pointer moved past the threshold: start the session from `view` with this event.
    let beginDrag: @MainActor (NSView, NSEvent) async -> Void

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.setAccessibilityElement(false)
        update(view)
        return view
    }

    func updateNSView(_ view: InteractionView, context: Context) { update(view) }

    private func update(_ view: InteractionView) {
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.prepareDrag = prepareDrag
        view.beginDrag = beginDrag
    }

    final class InteractionView: NSView {
        var onClick: (@MainActor (ChordModifiers) -> Void)?
        var onDoubleClick: (@MainActor () -> Void)?
        var prepareDrag: (@MainActor () -> Void)?
        var beginDrag: (@MainActor (NSView, NSEvent) async -> Void)?
        private var downPoint: NSPoint?
        private var dragStarted = false
        private static let threshold: CGFloat = 4

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent {
                if event.type == .rightMouseDown { return nil }
                if event.type == .leftMouseDown, event.modifierFlags.contains(.control) { return nil }
            }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            downPoint = convert(event.locationInWindow, from: nil)
            dragStarted = false
            prepareDrag?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragStarted, let downPoint else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - downPoint.x, point.y - downPoint.y) > Self.threshold else { return }
            dragStarted = true
            Task { await beginDrag?(self, event) }
        }

        override func mouseUp(with event: NSEvent) {
            defer { downPoint = nil }
            guard !dragStarted else { return }
            if event.clickCount >= 2 {
                onDoubleClick?()
            } else {
                onClick?(LibraryKeyTranslator.chordModifiers(event.modifierFlags))
            }
        }
    }
}
