import Foundation

// How an ordinary Flotsam window (Settings, the item shortcut editor, the setup guide) is brought in front of whatever
// app the user was in (FRD-008 FR-008-03, OC-8024), with no AppKit. Flotsam is an agent app and the Library is a
// non-activating panel, so when ⌘, or ⌘K is pressed in the Library another app is still the active one. On macOS 14 and
// later `NSApp.activate()` is only a request, and the system refuses it when the user is working in another app: the
// window then opens behind that app and the next key goes to it. So the sequence is fixed here, once, for every window:
// ask for activation, put the window in front and key, and if Flotsam is still not the frontmost app a moment later,
// have the system activate it the way a launch does.

/// The App's view of one window and of the application, as `WindowFronting` needs them.
@MainActor
public protocol FrontableWindow: AnyObject {
    /// Whether Flotsam is the frontmost application right now (what the system says, not what AppKit believes: a
    /// non-activating panel can make `NSApp.isActive` true while another app is still frontmost).
    var appIsActive: Bool { get }
    /// Whether the window is still on screen. A window closed during the grace period must not pull Flotsam forward.
    var windowIsOpen: Bool { get }
    /// The ordinary, cooperative request that Flotsam become the active application (`NSApp.activate()`).
    func requestAppActivation()
    /// Orders the window in front of every other window, even while Flotsam is not yet active, and makes it key.
    func orderFrontAndMakeKey()
    /// The stronger request used when the plain one was refused: ask the system (LaunchServices) to activate the app,
    /// as when it is opened from Finder. The activation policy is not touched, so there is no Dock icon.
    func forceAppActivation()
}

/// One per window. Owns the "is it active yet" follow-up so a second open cancels the first one's.
@MainActor
public final class WindowFronting {
    /// How long the plain request gets before it counts as refused.
    public static let activationGrace: Duration = .milliseconds(200)

    private let clock: any WallClock
    private var followUp: Task<Void, Never>?

    public init(clock: any WallClock) {
        self.clock = clock
    }

    /// Every "show this window" call goes here: request activation first, then show, then check it took.
    /// `forcing` is true for a window the user asked for (⌘, the menu-bar row, a Notice action, ⌘K, "Show Setup Guide…"):
    /// only then may a refused request be escalated to the system's activation. The setup guide shown by Flotsam itself at
    /// launch passes false, so a login-item start never takes the keyboard from the app the user is working in. A call
    /// with `forcing: false` also never cancels a follow-up an earlier forcing call left pending.
    public func bringToFront(_ window: any FrontableWindow, forcing: Bool = true) {
        window.requestAppActivation()
        window.orderFrontAndMakeKey()
        // A user's explicit open outranks a passive show: only a forcing call replaces a pending follow-up, so a
        // non-forcing one arriving inside the grace leaves the user's forced follow-up to run.
        guard forcing else { return }
        followUp?.cancel()
        followUp = Task { [clock] in
            await clock.sleep(for: Self.activationGrace)
            guard !Task.isCancelled, window.windowIsOpen, !window.appIsActive else { return }
            window.forceAppActivation()
            window.orderFrontAndMakeKey()
        }
    }
}
