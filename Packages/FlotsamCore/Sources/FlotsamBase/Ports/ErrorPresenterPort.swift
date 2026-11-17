import Foundation

/// A background failure listed under menu bar, Notices (FR-000-08 b).
public struct Notice: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let code: ErrorCode
    public let severity: ErrorSeverity
    /// The catalogue message, resolved when raised so the list keeps showing what the user was told.
    public let message: String
    public let date: Date

    public init(id: UUID = UUID(), code: ErrorCode, severity: ErrorSeverity, message: String, date: Date) {
        self.id = id
        self.code = code
        self.severity = severity
        self.message = message
        self.date = date
    }
}

/// The UI side of FR-000-08. `ErrorReporter` decides what surfaces and where; an adapter in the app target draws it.
///
/// Why a port: the decision (severity, origin, throttle) is logic that must be testable without AppKit, and the
/// drawing (a non-activating panel, a menu-bar badge, a modal alert) is platform code that must not leak into
/// FlotsamCore (ADR-0001, ADR-0011).
@MainActor
public protocol ErrorPresenter: AnyObject, Sendable {
    /// Small non-activating floating label, top-centre of the screen with the pointer, 2.5 s, no focus change.
    func showHUD(message: String)
    /// The full current Notices list, newest first. An empty list clears the menu-bar badge.
    func noticesChanged(_ notices: [Notice])
    /// Modal alert, then terminate (FR-000-04). Only called for a Fatal error.
    func presentFatal(_ error: FlotsamError)
}
