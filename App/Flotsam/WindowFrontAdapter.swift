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

    /// A miniaturized window is open: `isVisible` is false for it, and it must not suppress the follow-up while it is
    /// being brought back out of the Dock.
    var windowIsOpen: Bool { window.isVisible || window.isMiniaturized }

    var frontmostAppID: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    var appIsActive: Bool { frontmostAppID == ProcessInfo.processInfo.processIdentifier }

    func requestAppActivation() { NSApp.activate() }

    func orderFrontAndMakeKey() {
        // A miniaturized window ignores the ordering calls below: it has to come back out of the Dock first (FR-008-03).
        if window.isMiniaturized { window.deminiaturize(nil) }
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
