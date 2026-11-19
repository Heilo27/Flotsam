import Foundation

// How an ordinary Flotsam window (Settings, the item shortcut editor, the setup guide) is brought in front of whatever
// app the user was in (FRD-008 FR-008-03, OC-8024), with no AppKit. Flotsam is an agent app and the Library is a
// non-activating panel, so when ⌘, or ⌘K is pressed in the Library another app is still the active one. On macOS 14 and
// later `NSApp.activate()` is only a request, and the system refuses it when the user is working in another app: the
// window then opens behind that app and the next key goes to it. So the sequence is fixed here, once, for every window:
// ask for activation, put the window in front and key, and if the app is still not active a moment later, force it.

/// The App's view of one window and of the application, as `WindowFronting` needs them.
@MainActor
public protocol FrontableWindow: AnyObject {
    /// Whether Flotsam is the active application right now.
    var appIsActive: Bool { get }
    /// The ordinary, cooperative request that Flotsam become the active application (`NSApp.activate()`).
    func requestAppActivation()
    /// Orders the window in front of every other window, even while Flotsam is not yet active, and makes it key.
    func orderFrontAndMakeKey()
    /// The stronger request used when the plain one was refused: the app takes a regular activation policy so the
    /// system lets it activate, then activates.
    func forceAppActivation()
    /// Undoes `forceAppActivation`: back to an agent app with no Dock icon.
    func endForcedActivation()
}

/// One per window. Owns the "is it active yet" follow-up so a second open cancels the first one's.
@MainActor
public final class WindowFronting {
    /// How long the plain request gets before it counts as refused.
    public static let activationGrace: Duration = .milliseconds(200)
    /// How long a forced activation keeps the regular policy before it is undone.
    public static let forcedHold: Duration = .milliseconds(500)

    private let clock: any WallClock
    private var followUp: Task<Void, Never>?

    public init(clock: any WallClock) {
        self.clock = clock
    }

    /// Every "show this window" call goes here: request activation first, then show, then check it took.
    public func bringToFront(_ window: any FrontableWindow) {
        followUp?.cancel()
        window.requestAppActivation()
        window.orderFrontAndMakeKey()
        followUp = Task { [clock] in
            await clock.sleep(for: Self.activationGrace)
            guard !Task.isCancelled, !window.appIsActive else { return }
            window.forceAppActivation()
            window.orderFrontAndMakeKey()
            await clock.sleep(for: Self.forcedHold)
            // Undone even when a newer open cancelled this one: the policy must never stay changed.
            window.endForcedActivation()
        }
    }
}
