import Foundation

/// A permission a message may name (FR-000-06). Closed so the name shown to the user is always one of ours.
public enum PermissionName: String, CaseIterable, Sendable {
    case accessibility, inputMonitoring, screenshotFolder, pasteboard

    /// Catalogue key holding the localized permission name.
    var catalogueKey: String { "ui.permission.\(rawValue)" }
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

    /// Value handed to `String(format:)`. Counts stay integers so `%lld` works; the rest are pre-formatted text for `%@`.
    var formatArgument: CVarArg {
        switch self {
        case .count(let value): value
        case .byteSize(let value): MessageArgument.formatBytes(value)
        case .duration(let milliseconds): MessageArgument.formatDuration(milliseconds: milliseconds)
        case .permission(let name): FlotsamStrings.text(forKey: name.catalogueKey) ?? name.rawValue
        case .appName(let name): name
        }
    }

    /// Human-readable size in binary units (10 MiB reads "10 MB", per FR-007-06). One formatter so a limit reads the same in every message (ADR-0009).
    public static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// Human-readable duration such as "5 seconds", localized.
    public static func formatDuration(milliseconds: Int) -> String {
        Duration.milliseconds(milliseconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }
}
