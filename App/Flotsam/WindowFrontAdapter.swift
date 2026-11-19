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

    /// Brings the window in front of the app the user was in and makes it key (FR-008-03).
    func bringToFront() { fronting.bringToFront(self) }

    var appIsActive: Bool { NSApp.isActive }

    func requestAppActivation() { NSApp.activate() }

    func orderFrontAndMakeKey() {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func forceAppActivation() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func endForcedActivation() { NSApp.setActivationPolicy(.accessory) }
}
