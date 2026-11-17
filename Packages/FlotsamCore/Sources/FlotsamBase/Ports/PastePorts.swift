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

/// Which application is frontmost right now.
@MainActor
public protocol FrontmostAppProvider {
    func frontmost() -> FrontmostApp?
}

/// Posts ⌘V (key code 9 with the Command flag, key down then key up) to the session event tap (FR-003-15 step 6).
@MainActor
public protocol KeyEventPoster {
    /// False when the events could not be created or posted.
    func postPaste() -> Bool
}
