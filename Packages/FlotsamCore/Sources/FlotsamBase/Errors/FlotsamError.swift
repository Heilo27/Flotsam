import Foundation

/// Domain and integer code of a lower-level error (FR-000-01).
///
/// Why this shape: `localizedDescription` and `userInfo` routinely embed file paths and user-chosen names, and
/// FR-000-10 forbids those in anything that can be logged or copied into a bug report. A domain string plus an
/// integer identifies a failure well enough to diagnose it (`NSCocoaErrorDomain` 640 is "out of disk") and can
/// carry no content.
public struct UnderlyingErrorInfo: Sendable, Equatable {
    public let domain: String
    public let code: Int

    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }

    /// Captures only the domain and code of a system error. This is the one place a foreign `Error` is converted,
    /// so no call site is tempted to reach for `localizedDescription`.
    public init(_ error: any Error) {
        let bridged = error as NSError
        self.init(domain: bridged.domain, code: bridged.code)
    }
}

/// The one error type that crosses module boundaries (FR-000-01, FR-000-02).
///
/// Why a value type with no free-text field: every failure must be safe to log, show in a Notice and list in a
/// diagnostics report (FR-000-10). The only text is `internalMessage`, a `StaticString`, which the compiler
/// guarantees is a literal with no interpolated user data. Everything dynamic goes through `context`, whose value
/// type (`LogSafeValue`) has no way to hold clip text, a path or a URL.
public struct FlotsamError: Error, Sendable, Equatable {
    public let code: ErrorCode
    /// Static English literal for developers and logs. Never shown to the user; the user text comes from the
    /// catalogue (`FlotsamStrings`) so wording has one home (FR-000-05).
    public let internalMessage: StaticString
    public let context: [LogKey: LogSafeValue]
    public let underlying: UnderlyingErrorInfo?

    /// Derived from the code, never supplied by the caller (FR-000-01), so one failure cannot be Fatal at one call
    /// site and a Warning at another.
    public var severity: ErrorSeverity { code.severity }

    public init(
        _ code: ErrorCode,
        _ internalMessage: StaticString,
        context: [LogKey: LogSafeValue] = [:],
        underlying: UnderlyingErrorInfo? = nil
    ) {
        self.code = code
        self.internalMessage = internalMessage
        self.context = context
        self.underlying = underlying
    }

    /// Equality ignores `internalMessage`: two errors are the same failure when the code, context and cause agree.
    /// (`StaticString` is not `Equatable`, and wording is not identity.)
    public static func == (lhs: FlotsamError, rhs: FlotsamError) -> Bool {
        lhs.code == rhs.code && lhs.context == rhs.context && lhs.underlying == rhs.underlying
    }
}

/// Every fallible operation in the app returns this (FR-000-01). `Result` rather than `throws` so a failure is part
/// of the signature and cannot escape a module boundary as an untyped `Error`, `NSError` or `String` (FR-000-02).
public typealias FlotsamResult<Value: Sendable> = Result<Value, FlotsamError>
