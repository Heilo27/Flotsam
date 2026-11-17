import Foundation

/// A shelf interaction FR-000-11 requires a log line for.
public enum ShelfAction: String, Sendable, Equatable { case reveal, dragOut, dropIn }

/// A database step FR-000-11 requires a log line for.
public enum DatabaseStep: String, Sendable, Equatable { case open, migrate, integrityCheck }

/// The mandatory instrumented callsites of FR-000-11, one case each.
///
/// Why an enum of typed payloads rather than a free `log(name, fields)`: the FRD says each callsite "logs code or
/// outcome only". With these cases a module cannot attach anything the callsite is not entitled to, and the set
/// of lines the app can emit is greppable in one file. Owning modules call `FlotsamLog.log(_:)` at the moment the
/// thing happens (Storage for database and retention events, Capture for pasteboard and so on). Warning, Error
/// and Fatal raises are the other half of FR-000-11 and go through `ErrorReporter`.
public enum LogEvent: Sendable, Equatable {
    /// Pasteboard change processed. `policy` carries the `POL` code when the outcome is `.skipped`.
    case pasteboardProcessed(kind: ItemKind?, byteSize: Int, outcome: LogOutcome, policy: ErrorCode?)
    case screenshotImported(outcome: LogOutcome, byteSize: Int)
    case pasteBack(outcome: LogOutcome)
    case hotkeyRegistered(outcome: LogOutcome)
    case shelf(ShelfAction, outcome: LogOutcome)
    /// Matched yes or no only; the typed buffer and the trigger string never appear (FR-000-10).
    case triggerMatched(Bool)
    case permissionChanged(PermissionName, granted: Bool)
    case retentionSwept(rows: Int, bytes: Int)
    case database(DatabaseStep, outcome: LogOutcome)

    /// Stable dotted name, the first token of the log line and the thing a log search matches on.
    public var name: String {
        switch self {
        case .pasteboardProcessed: "pasteboard.processed"
        case .screenshotImported: "screenshot.imported"
        case .pasteBack: "paste.back"
        case .hotkeyRegistered: "hotkey.registered"
        case .shelf(let action, _): "shelf.\(action.rawValue)"
        case .triggerMatched: "trigger.matched"
        case .permissionChanged: "permission.changed"
        case .retentionSwept: "retention.swept"
        case .database(let step, _): "database.\(step.rawValue)"
        }
    }

    public var category: LogCategory {
        switch self {
        case .pasteboardProcessed: .capture
        case .screenshotImported: .screenshots
        case .pasteBack: .library
        case .hotkeyRegistered, .triggerMatched: .triggers
        case .shelf: .shelf
        case .permissionChanged: .settings
        case .retentionSwept, .database: .storage
        }
    }

    public var fields: [LogKey: LogSafeValue] {
        switch self {
        case let .pasteboardProcessed(kind, byteSize, outcome, policy):
            var fields: [LogKey: LogSafeValue] = [.byteSize: .bytes(byteSize), .outcome: .outcome(outcome)]
            if let kind { fields[.kind] = .kind(kind) }
            if let policy { fields[.code] = .code(policy) }
            return fields
        case let .screenshotImported(outcome, byteSize):
            return [.outcome: .outcome(outcome), .byteSize: .bytes(byteSize)]
        case .pasteBack(let outcome), .hotkeyRegistered(let outcome), .shelf(_, let outcome), .database(_, let outcome):
            return [.outcome: .outcome(outcome)]
        case .triggerMatched(let matched):
            return [.outcome: .outcome(matched ? .matched : .noMatch)]
        case let .permissionChanged(permission, granted):
            return [.permission: .permission(permission), .outcome: .outcome(granted ? .granted : .denied)]
        case let .retentionSwept(rows, bytes):
            return [.rows: .int(rows), .byteSize: .bytes(bytes)]
        }
    }
}
