import Foundation
import os

/// One category per module (FR-000-09). `ErrorCode.logCategory` maps a code to its module's category.
public enum LogCategory: String, CaseIterable, Sendable {
    case core, capture, screenshots, library, organize, triggers, shelf, storage, settings
}

/// Keys allowed in an error or log context. Free text is not a key.
public enum LogKey: String, Sendable {
    case itemId, count, byteSize, durationMs, bundleId, kind, step, limitBytes
    case uti, outcome, code, permission, rows
}

/// What happened at an instrumented callsite (FR-000-11). A closed list so an outcome is an enum raw value, which
/// FR-000-10 allows in the clear, and never a free-text reason.
public enum LogOutcome: String, Sendable, Equatable {
    case stored, deduped, skipped, started, succeeded, failed
    case matched, noMatch, granted, denied, registered, revealed, draggedOut, droppedIn, opened, migrated, passed
}

/// Values allowed in an error or log context. There is deliberately no free-text case:
/// clip text, paths, URLs and keystrokes can never be logged (TRUTHS anti-truth A4, FR-000-10).
public enum LogSafeValue: Sendable, Equatable {
    case int(Int)
    case bool(Bool)
    case id(UUID)
    case bundleId(String)
    case bytes(Int)
    case milliseconds(Int)
    case kind(ItemKind)
    /// A pasteboard type identifier: a format name such as `public.utf8-plain-text`, never data.
    case uti(String)
    case outcome(LogOutcome)
    case code(ErrorCode)
    case permission(PermissionName)

    var rendered: String {
        switch self {
        case .int(let value): String(value)
        case .bool(let value): String(value)
        case .id(let value): value.uuidString
        case .bundleId(let value): value
        case .bytes(let value): "\(value)B"
        case .milliseconds(let value): "\(value)ms"
        case .kind(let value): value.rawValue
        case .uti(let value): value
        case .outcome(let value): value.rawValue
        case .code(let value): value.rawValue
        case .permission(let value): value.rawValue
        }
    }

    /// True only for the FR-000-10 allowlist: counts, byte sizes, durations, booleans, enum raw values, item kind,
    /// error codes and pasteboard type identifiers. Item ids and source-app bundle identifiers are not on it, so
    /// they log `.private` and a release build shows `<private>` for them. An exhaustive switch with no `default`
    /// means a new case cannot be added without deciding its privacy.
    var isPublic: Bool {
        switch self {
        case .int, .bool, .bytes, .milliseconds, .kind, .uti, .outcome, .code, .permission: true
        case .id, .bundleId: false
        }
    }
}

/// The one place `os.Logger` is used (FR-000-09, FR-000-10). Centralising it is what lets a lint prove every
/// interpolated value carries an explicit privacy qualifier.
public enum FlotsamLog {
    public static let fallbackSubsystem = "io.github.heilo27.Flotsam"

    /// Subsystem is the app bundle identifier (FR-000-09); the package fallback applies under `swift test`.
    static var subsystem: String { Bundle.main.bundleIdentifier ?? fallbackSubsystem }

    static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// FR-000-09 level mapping: Info to `.info`, Warning to `.notice`, Error to `.error`, Fatal to `.fault`.
    static func level(for severity: ErrorSeverity) -> OSLogType {
        switch severity {
        case .info: .info
        case .warning: .default
        case .error: .error
        case .fatal: .fault
        }
    }

    /// Splits a context into the part that may be logged in the clear and the part that must stay private.
    /// Sorted so one failure always renders the same line, which keeps log searches and diffs stable.
    static func render(_ context: [LogKey: LogSafeValue]) -> (publicPart: String, privatePart: String) {
        func line(_ isPublic: Bool) -> String {
            context
                .filter { $0.value.isPublic == isPublic }
                .map { "\($0.key.rawValue)=\($0.value.rendered)" }
                .sorted()
                .joined(separator: " ")
        }
        return (line(true), line(false))
    }

    /// Logs an error's code, severity and safe context. The static message and the underlying cause are logged
    /// `.private`: neither is on the FR-000-10 allowlist, and the code already identifies the failure.
    public static func log(_ error: FlotsamError, category: LogCategory? = nil) {
        let logger = logger(category ?? error.code.logCategory)
        let parts = render(error.context)
        let message = "\(error.internalMessage)"
        let cause = error.underlying.map { "\($0.domain):\($0.code)" } ?? ""
        logger.log(
            level: level(for: error.severity),
            """
            \(error.code.rawValue, privacy: .public) \(error.severity.rawValue, privacy: .public) \
            \(parts.publicPart, privacy: .public) \(parts.privatePart, privacy: .private) \
            \(message, privacy: .private) \(cause, privacy: .private)
            """
        )
    }

    /// Logs a successful or skipped outcome at an instrumented callsite (FR-000-11) at `.info`.
    public static func log(_ event: LogEvent) {
        let parts = render(event.fields)
        logger(event.category).info(
            "\(event.name, privacy: .public) \(parts.publicPart, privacy: .public) \(parts.privatePart, privacy: .private)"
        )
    }

    /// Verbose developer trace at `.debug`, compiled out of release builds (FR-000-09). Call sites that want the
    /// literal gone from the binary too wrap the call in `#if DEBUG`. The message is a `StaticString`, so it cannot
    /// carry content, and it is logged `.private` like every other non-allowlisted value.
    public static func trace(_ message: StaticString, category: LogCategory = .core, context: [LogKey: LogSafeValue] = [:]) {
        #if DEBUG
        let parts = render(context)
        logger(category).debug(
            "\("\(message)", privacy: .private) \(parts.publicPart, privacy: .public) \(parts.privatePart, privacy: .private)"
        )
        #endif
    }
}
