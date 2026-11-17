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

/// A source-app bundle identifier that has been checked to be reverse-DNS shaped: two or more dot-separated labels of
/// ASCII letters, digits and hyphens, at most 255 characters. Construction fails for anything else.
///
/// Why a validated type and not a `String`: a bare string case would let a call site log a file name, a URL or clip
/// text under the label "bundle id". Shape validation rejects spaces, slashes, colons and `@`, which every path, URL
/// and sentence contains. It cannot prove the value is an app and not a domain name the user typed, so
/// `LogSafeValue` still logs it `.private` (FR-000-10: source-app bundle identifiers are never public).
public struct BundleIdentifier: Sendable, Equatable {
    public let value: String

    public init?(_ candidate: String) {
        guard candidate.utf8.count <= 255 else { return nil }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels where label.isEmpty || !label.allSatisfy({ allowed.contains($0) }) { return nil }
        value = candidate
    }
}

/// A pasteboard type identifier. Public in a log only when it is one of the closed list of system-declared types
/// below; any other identifier (an app's own type, a `dyn.` identifier that encodes a file extension or tag, or
/// something that is not a type at all) is logged `.private`.
///
/// Why not trust the string: a UTI is whatever the writing app put on the pasteboard, so an unfiltered public UTI
/// is an arbitrary string in the clear. Only identifiers Apple declares carry no user content by construction.
public struct PasteboardTypeID: Sendable, Equatable {
    public let identifier: String

    public init(_ identifier: String) { self.identifier = identifier }

    /// System-declared identifiers that can be logged in the clear. Closed: adding one is a deliberate change.
    static let systemDeclared: Set<String> = [
        "public.utf8-plain-text", "public.utf16-plain-text", "public.utf16-external-plain-text", "public.plain-text",
        "public.text", "public.html", "public.rtf", "public.url", "public.file-url", "public.png", "public.tiff",
        "public.jpeg", "public.heic", "public.image", "public.data", "public.vcard", "public.folder",
        "com.apple.rtfd", "com.adobe.pdf", "NSStringPboardType",
    ]

    var isSystemDeclared: Bool { Self.systemDeclared.contains(identifier) }
}

/// Values allowed in an error or log context. There is deliberately no free-text case:
/// clip text, paths, URLs and keystrokes can never be logged (TRUTHS anti-truth A4, FR-000-10). The two cases that
/// wrap a string-shaped value take a validating type (`BundleIdentifier`) or a classified one (`PasteboardTypeID`),
/// so a call site cannot hand them arbitrary text and have it logged in the clear.
public enum LogSafeValue: Sendable, Equatable {
    case int(Int)
    case bool(Bool)
    case id(UUID)
    case bundleId(BundleIdentifier)
    case bytes(Int)
    case milliseconds(Int)
    case kind(ItemKind)
    /// A pasteboard type identifier such as `public.utf8-plain-text`, never data. Public only if system-declared.
    case uti(PasteboardTypeID)
    case outcome(LogOutcome)
    case code(ErrorCode)
    case permission(PermissionName)

    var rendered: String {
        switch self {
        case .int(let value): String(value)
        case .bool(let value): String(value)
        case .id(let value): value.uuidString
        case .bundleId(let value): value.value
        case .bytes(let value): "\(value)B"
        case .milliseconds(let value): "\(value)ms"
        case .kind(let value): value.rawValue
        case .uti(let value): value.identifier
        case .outcome(let value): value.rawValue
        case .code(let value): value.rawValue
        case .permission(let value): value.rawValue
        }
    }

    /// True only for the FR-000-10 allowlist: counts, byte sizes, durations, booleans, enum raw values, item kind,
    /// error codes and system-declared pasteboard type identifiers. Item ids, source-app bundle identifiers and any
    /// pasteboard type outside the system list are not on it, so they log `.private` and a release build shows
    /// `<private>` for them. An exhaustive switch with no `default` means a new case cannot be added without
    /// deciding its privacy.
    var isPublic: Bool {
        switch self {
        case .int, .bool, .bytes, .milliseconds, .kind, .outcome, .code, .permission: true
        case .uti(let type): type.isSystemDeclared
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
