/// Domain and integer code of a lower-level error. Never the localized description (it can embed paths). FR-000-01.
public struct UnderlyingErrorInfo: Sendable, Equatable {
    public let domain: String
    public let code: Int

    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }
}

/// The one error type that crosses module boundaries (FR-000-01, FR-000-02).
public struct FlotsamError: Error, Sendable, Equatable {
    public let code: ErrorCode
    /// Static English literal, no user data.
    public let internalMessage: StaticString
    public let context: [LogKey: LogSafeValue]
    public let underlying: UnderlyingErrorInfo?

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

    public static func == (lhs: FlotsamError, rhs: FlotsamError) -> Bool {
        lhs.code == rhs.code && lhs.context == rhs.context && lhs.underlying == rhs.underlying
    }
}

/// Every fallible operation in the app returns this (FR-000-01).
public typealias FlotsamResult<Value: Sendable> = Result<Value, FlotsamError>
