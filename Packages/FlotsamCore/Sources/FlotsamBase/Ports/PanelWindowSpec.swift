import Foundation

/// How a Flotsam panel behaves as a window, as plain facts the App maps onto an `NSPanel` (FRD-003 FR-003-01,
/// FRD-006 FR-006-02). The panels are key-capable without activating Flotsam, so the app being pasted into stays
/// frontmost; they float, join every Space and may sit over a full-screen app.
///
/// The App's adapter (`PanelWindowSpec.apply(to:)`, App/Platform) is the only place these become AppKit flags, so a test
/// can pin the decision here and a second test can pin the mapping.
public struct PanelWindowSpec: Sendable, Equatable {
    /// `nonactivatingPanel`: the panel can take key without making Flotsam the active application.
    public let isNonActivating: Bool
    /// Window level `.floating` and `isFloatingPanel`.
    public let isFloating: Bool
    /// `canJoinAllSpaces`: appears on the active Space without switching Spaces.
    public let joinsAllSpaces: Bool
    /// `fullScreenAuxiliary`: may be shown over a full-screen app.
    public let isFullScreenAuxiliary: Bool
    /// `ignoresCycle`: excluded from window cycling (⌘`).
    public let ignoresWindowCycling: Bool
    /// `hidesOnDeactivate`: hides when Flotsam deactivates. False for both panels (they hide by their own rules).
    public let hidesOnDeactivate: Bool
    /// The user can resize it by dragging an edge (`resizable` style).
    public let isResizable: Bool
    /// The user can move it by dragging its background.
    public let isMovableByBackground: Bool

    public init(
        isNonActivating: Bool, isFloating: Bool, joinsAllSpaces: Bool, isFullScreenAuxiliary: Bool,
        ignoresWindowCycling: Bool, hidesOnDeactivate: Bool, isResizable: Bool, isMovableByBackground: Bool
    ) {
        self.isNonActivating = isNonActivating
        self.isFloating = isFloating
        self.joinsAllSpaces = joinsAllSpaces
        self.isFullScreenAuxiliary = isFullScreenAuxiliary
        self.ignoresWindowCycling = ignoresWindowCycling
        self.hidesOnDeactivate = hidesOnDeactivate
        self.isResizable = isResizable
        self.isMovableByBackground = isMovableByBackground
    }
}
