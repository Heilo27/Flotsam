import AppKit
import FlotsamShelf

/// The collapsed bar at the Shelf's edge (FRD-006 FR-006-37): a small non-activating panel the pointer can rest on to
/// open the Shelf. Opt-in (`shelf.edgeBar`).
///
/// Why this costs nothing while idle (TRUTHS S5, FR-006-17): the bar is a static layer-backed view with no animation, no
/// timer and no monitor of its own. Hover comes from one tracking area, which the window server drives: it wakes the
/// app only when the pointer enters or leaves the bar, never to sample the pointer. What happens next is the Shelf's own
/// reveal path (`ShelfRevealMachine`, `.onBar`), so there is no second reveal mechanism.
@MainActor
final class ShelfEdgeBar {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// The bar itself: a rounded pill in the system's secondary label colour, redrawn only when the appearance changes.
    private final class BarView: NSView {
        var onPointerMoved: (@MainActor () -> Void)?
        private var area: NSTrackingArea?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel(ShelfText.string(ShelfText.edgeBar))
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") } // fatal-ok: AppKit-required initialiser; the view is built in code, never decoded

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            let thickness = min(bounds.width, bounds.height)
            layer?.cornerRadius = thickness / 2
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let fresh = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(fresh)
            area = fresh
        }

        override func mouseEntered(with event: NSEvent) { onPointerMoved?() }
        override func mouseExited(with event: NSEvent) { onPointerMoved?() }
    }

    private let panel: Panel

    /// `onPointerMoved` is called when the pointer enters or leaves the bar; the controller re-reads where it is.
    init(onPointerMoved: @escaping @MainActor () -> Void) {
        panel = Panel(
            contentRect: .zero, styleMask: ShelfWindowPolicy.windowSpec.styleMask(adding: [.borderless]),
            backing: .buffered, defer: true)
        ShelfWindowPolicy.windowSpec.apply(to: panel)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let view = BarView(frame: .zero)
        view.onPointerMoved = onPointerMoved
        panel.contentView = view
    }

    /// The bar's frame in screen coordinates, which the pointer classifier tests against.
    var frame: CGRect { panel.frame }

    func place(_ frame: CGRect) {
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: false)
        panel.contentView?.needsDisplay = true
    }

    func show() { panel.orderFrontRegardless() }

    func hide() { panel.orderOut(nil) }
}
