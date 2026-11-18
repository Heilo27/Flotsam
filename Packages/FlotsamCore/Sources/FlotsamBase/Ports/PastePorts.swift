import Foundation

// Ports for paste-back (ADR-0005). Real adapters live in the app target's Platform folder.

/// The application a paste is aimed at: recorded when the Library opens, compared again just before ⌘V (FR-003-02,
/// FR-003-15).
public struct FrontmostApp: Sendable, Equatable {
    public let bundleId: String?
    public let processId: Int32

    public init(bundleId: String?, processId: Int32) {
        self.bundleId = bundleId
        self.processId = processId
    }
}

/// The one decision behind every synthetic post (ADR-0005, FR-003-16, FR-005-14): a key may be posted to `target` only
/// when `target` is the frontmost application right now and its process is still running. The real adapter and the test
/// fake both call this, so neither can drift from the other.
public enum PostGuard {
    /// - Parameters:
    ///   - target: the application the post is addressed to.
    ///   - frontmost: the frontmost application read immediately before posting; nil when none could be read.
    ///   - targetIsRunning: true only when `target`'s process was found and has not terminated.
    public static func allowsPost(to target: FrontmostApp, frontmost: FrontmostApp?, targetIsRunning: Bool) -> Bool {
        frontmost == target && targetIsRunning
    }
}

/// Which application is frontmost right now.
@MainActor
public protocol FrontmostAppProvider {
    func frontmost() -> FrontmostApp?
}

/// Posts ⌘V (key code 9 with the Command flag, key down then key up) to the paste target's process (FR-003-15 step 6).
@MainActor
public protocol KeyEventPoster {
    /// Addresses ⌘V to `target` itself, never to whichever application holds focus when the event is delivered, so a
    /// focus change after the caller's check cannot send the clip elsewhere (FR-003-16). The adapter re-checks that
    /// `target` is still frontmost immediately before posting. False when `target` is no longer the frontmost
    /// application, or the events could not be created or posted; nothing is posted then.
    func postPaste(to target: FrontmostApp) -> Bool
}
