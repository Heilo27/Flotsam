import AppKit
import FlotsamBase

/// `NSWindow` and `NSApp` behind `FrontableWindow`. The sequence and the follow-up are `WindowFronting`'s (FlotsamBase,
/// where it is tested); this only names the AppKit calls. The one place an ordinary window is activated and ordered front.
@MainActor
final class WindowFrontAdapter: FrontableWindow {
    private let window: NSWindow
    private let fronting = WindowFronting(clock: SystemClock())

    init(window: NSWindow) {
        self.window = window
    }

    /// Brings the window in front of the app the user was in and makes it key (FR-008-03). `forcing: false` for a show
    /// the user did not ask for (the setup guide at launch): the plain request only, never the system activation.
    func bringToFront(forcing: Bool = true) { fronting.bringToFront(self, forcing: forcing) }

    var windowIsOpen: Bool { window.isVisible }

    var appIsActive: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    func requestAppActivation() { NSApp.activate() }

    func orderFrontAndMakeKey() {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    /// `NSApp.activate()` is refused while another app is frontmost, and so is every in-process variant (checked on
    /// macOS 26: `activate(ignoringOtherApps:)`, `NSRunningApplication.activate`, a policy flip). Opening the app's own
    /// bundle through LaunchServices with `activates` is honoured.
    func forceAppActivation() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // A refusal leaves the window ordered front exactly as before; there is no further step to take, and the
        // log vocabulary (FR-000-11) has no line for it.
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
    }
}
