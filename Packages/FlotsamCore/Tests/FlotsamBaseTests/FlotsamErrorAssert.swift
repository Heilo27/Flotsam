import FlotsamBase
import Testing

/// Asserts everything a log line carries from a `FlotsamError`: code, context, underlying cause and `internalMessage`
/// verbatim. `FlotsamError ==` ignores `internalMessage` (FlotsamError.swift), so `#expect(error == FlotsamError(code, "x"))`
/// cannot catch a wrong log message; use this wherever an FRD or a test needs the logged text pinned.
///
/// One source file, no test target of its own: FlotsamBaseTests owns it and every other test target links it with a
/// symlink (see FlotsamShelfTests/FlotsamErrorAssert.swift, as SignpostProbe.swift does), so it is never copied and the
/// package's target list and bin/check-architecture.sh are untouched. To use it in another target, symlink the same file.
///
/// - Parameter message: the exact `internalMessage` text, compared character for character.
func expectFlotsamError(
    _ actual: FlotsamError,
    code: ErrorCode,
    message: String,
    context: [LogKey: LogSafeValue] = [:],
    underlying: UnderlyingErrorInfo? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(actual.code == code, "code", sourceLocation: sourceLocation)
    #expect("\(actual.internalMessage)" == message, "internalMessage", sourceLocation: sourceLocation)
    #expect(actual.context == context, "context", sourceLocation: sourceLocation)
    #expect(actual.underlying == underlying, "underlying", sourceLocation: sourceLocation)
}
