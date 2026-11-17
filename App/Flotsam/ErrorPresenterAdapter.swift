import AppKit
import FlotsamBase
import Observation

/// Draws what `ErrorReporter` decides to surface (FR-000-08): the HUD, the Notices list and menu-bar badge, and the
/// Fatal alert. Holds no policy; throttling, severity and origin rules live in FlotsamCore so they are testable.
@MainActor
@Observable
final class ErrorPresenterAdapter: ErrorPresenter {
    private(set) var notices: [Notice] = []
    var hasBadge: Bool { !notices.isEmpty }

    @ObservationIgnored private let dataFolder: URL
    @ObservationIgnored private var hudPanel: NSPanel?
    @ObservationIgnored private var hudLabel: NSTextField?
    @ObservationIgnored private var hudHideTask: Task<Void, Never>?

    init(dataFolder: URL) {
        self.dataFolder = dataFolder
    }

    func noticesChanged(_ notices: [Notice]) {
        self.notices = notices
    }

    func presentFatal(_ error: FlotsamError) {
        FatalAlert.present(for: error, dataFolder: dataFolder)
    }

    /// A small non-activating label, top-centre of the screen holding the pointer, for 2.5 s (FR-000-08 a).
    /// Why `.nonactivatingPanel` with mouse events ignored: the user is mid-task in another app; the HUD must
    /// neither take focus nor intercept a click.
    func showHUD(message: String) {
        let panel = hudPanel ?? makeHUDPanel()
        guard let label = hudLabel else { return }
        label.stringValue = message
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 32, height: label.frame.height + 20)
        panel.setContentSize(size)
        label.frame.origin = NSPoint(x: 16, y: 10)
        panel.setFrameOrigin(topCentre(for: size))
        panel.orderFrontRegardless()
        announceToVoiceOver(message)

        hudHideTask?.cancel()
        hudHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.hudPanel?.orderOut(nil)
        }
    }

    private func makeHUDPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let label = NSTextField(wrappingLabelWithString: "")
        label.preferredMaxLayoutWidth = 380
        label.alignment = .center
        label.maximumNumberOfLines = 0
        background.addSubview(label)
        panel.contentView = background
        hudPanel = panel
        hudLabel = label
        return panel
    }

    private func topCentre(for size: NSSize) -> NSPoint {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        return NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 12)
    }

    /// The HUD never takes focus, so VoiceOver would not otherwise hear it.
    private func announceToVoiceOver(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }
}
