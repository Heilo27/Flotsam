import Foundation

/// A permission a message may name (FR-000-06). Closed so the name shown to the user is always one of ours.
public enum PermissionName: String, CaseIterable, Sendable {
    case accessibility, inputMonitoring, screenshotFolder, pasteboard

    /// Catalogue key holding the localized permission name.
    var catalogueKey: String { "ui.permission.\(rawValue)" }
}

/// The kind of value a format specifier in a catalogue template accepts (FR-000-05). `%lld` takes an integer, `%@`
/// takes text; handing either the other kind crashes or prints garbage, so rendering checks kinds first.
public enum MessageArgumentKind: Sendable, Equatable {
    case integer
    case text
}

/// The only values a user-facing message may interpolate (FR-000-06): counts, byte sizes, durations, permission
/// names and the display name of an app.
///
/// Why a closed enum rather than `CVarArg`: the FRD forbids interpolating clip text, URLs, file or folder names,
/// notes, tags, trigger strings and search queries, and a raw `String` parameter would let any of them through.
/// With this type the compiler rejects them. `appName` is the one free-text case; it takes an app's display name
/// only (never a bundle identifier, which FR-000-10 treats as private).
public enum MessageArgument: Sendable, Equatable {
    case count(Int)
    case byteSize(Int)
    case duration(milliseconds: Int)
    case permission(PermissionName)
    case appName(String)

    /// The format specifier this argument can fill: an integer for `%lld`, text for `%@`.
    var kind: MessageArgumentKind {
        switch self {
        case .count: .integer
        case .byteSize, .duration, .permission, .appName: .text
        }
    }

    /// Value handed to `String(format:)`. Counts stay integers so `%lld` works; the rest are pre-formatted text for `%@`.
    /// A negative count becomes 0 (FR-000-06), the same clamp `DiagnosticsSnapshotBuilder` applies. An app name longer
    /// than `appNameLimit` characters is cut to that length ending in "…" so the message fits its 140-character budget.
    func formatArgument(appNameLimit: Int = .max) -> CVarArg {
        switch self {
        case .count(let value): max(0, value)
        case .byteSize(let value): MessageArgument.formatBytes(value)
        case .duration(let milliseconds): MessageArgument.formatDuration(milliseconds: milliseconds)
        case .permission(let name): FlotsamStrings.text(forKey: name.catalogueKey) ?? name.rawValue
        case .appName(let name):
            name.count > appNameLimit ? String(name.prefix(max(0, appNameLimit - 1))) + "\u{2026}" : name
        }
    }

    /// Human-readable size in binary units (10 MiB reads "10 MB", per FR-007-06). One formatter so a limit reads the same in every message (ADR-0009).
    /// A negative size reads as 0, and zero reads in digits ("0 bytes"), never as the word "Zero KB" (FR-000-06).
    public static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(max(0, bytes)))
    }

    /// Human-readable duration such as "5 seconds", localized. A negative duration reads as 0.
    public static func formatDuration(milliseconds: Int) -> String {
        Duration.milliseconds(max(0, milliseconds)).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }
}
