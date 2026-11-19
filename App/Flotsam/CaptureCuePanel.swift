import AppKit
import FlotsamBase

/// Draws the quiet capture cue (FR-001-30): a small label that appears for a moment and goes. Distinct from the error
/// HUD (FR-000-08), which it does not share a panel, a throttle or a position with: the cue sits bottom-centre, the
/// HUD top-centre.
///
/// Why a non-activating panel with mouse events ignored: the user is mid-task in another app; the cue must neither
/// take focus nor intercept a click. It makes no sound and no VoiceOver announcement (a copy is not news). Nothing
/// runs while it is hidden: the panel is built at the first cue and the only timer is the one-shot dismiss (S5).
@MainActor
final class CaptureCuePanel {
    /// How long one cue stays up. A newer cue restarts it.
    private static let visibleFor: Duration = .milliseconds(1200)

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideTask: Task<Void, Never>?

    func show(_ kind: CaptureCueKind) {
        let panel = self.panel ?? makePanel()
        guard let label else { return }
        label.stringValue = kind.message
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 28, height: label.frame.height + 14)
        panel.setContentSize(size)
        label.frame.origin = NSPoint(x: 14, y: 7)
        panel.setFrameOrigin(bottomCentre(for: size))
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = .center
        background.addSubview(label)
        panel.contentView = background
        self.panel = panel
        self.label = label
        return panel
    }

    private func bottomCentre(for size: NSSize) -> NSPoint {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        return NSPoint(x: area.midX - size.width / 2, y: area.minY + 24)
    }
}
