import Foundation

/// State of one permission as the report shows it.
public enum PermissionState: String, Sendable, Equatable { case granted, denied, notDetermined }

/// Build and system facts. Separate from `DiagnosticsSnapshot` so tests can supply fixed values.
public struct DiagnosticsEnvironment: Sendable, Equatable {
    public let appVersion: String
    public let build: String
    public let macOSVersion: String
    public let cpuArchitecture: String

    public init(appVersion: String, build: String, macOSVersion: String, cpuArchitecture: String) {
        self.appVersion = appVersion
        self.build = build
        self.macOSVersion = macOSVersion
        self.cpuArchitecture = cpuArchitecture
    }

    public static var current: DiagnosticsEnvironment {
        let info = Bundle.main.infoDictionary
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return DiagnosticsEnvironment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info?["CFBundleVersion"] as? String ?? "unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            cpuArchitecture: architecture
        )
    }
}

/// Every field FR-000-14 lists, and nothing else.
///
/// Why a closed struct of typed fields: the report is the one artifact a user pastes into a public bug report, so
/// its content must be provable by reading this type. There is no free-text field, no dictionary of arbitrary
/// strings (toggle keys are setting-registry names, not values a user typed) and no list of ignored apps; FR-000-10
/// forbids all of them.
public struct DiagnosticsSnapshot: Sendable, Equatable {
    public var environment: DiagnosticsEnvironment
    public var permissions: [PermissionName: PermissionState]
    public var retention: RetentionPreset
    public var imageBudget: ImageBudget
    /// Setting-registry key to on/off, for the boolean settings. Values only, never user-entered lists.
    public var toggles: [String: Bool]
    public var itemCounts: [ItemKind: Int]
    public var databaseBytes: Int
    public var blobBytes: Int
    public var recentErrors: [RaisedError]

    public init(
        environment: DiagnosticsEnvironment,
        permissions: [PermissionName: PermissionState],
        retention: RetentionPreset,
        imageBudget: ImageBudget,
        toggles: [String: Bool],
        itemCounts: [ItemKind: Int],
        databaseBytes: Int,
        blobBytes: Int,
        recentErrors: [RaisedError]
    ) {
        self.environment = environment
        self.permissions = permissions
        self.retention = retention
        self.imageBudget = imageBudget
        self.toggles = toggles
        self.itemCounts = itemCounts
        self.databaseBytes = databaseBytes
        self.blobBytes = blobBytes
        self.recentErrors = recentErrors
    }
}

/// Renders the FR-000-14 plain-text report.
///
/// The labels are fixed English on purpose: the report is read by a developer in a bug thread, not shown in the
/// app's UI, so it is not a user-facing string under FR-000-05 and stays greppable and diff-able across locales.
public enum DiagnosticsReport {
    public static func render(_ snapshot: DiagnosticsSnapshot) -> String {
        let time = ISO8601DateFormatter()
        var lines: [String] = ["Flotsam diagnostics", ""]
        let env = snapshot.environment
        lines += [
            "App: \(env.appVersion) (\(env.build))",
            "macOS: \(env.macOSVersion)",
            "CPU: \(env.cpuArchitecture)",
            "",
            "Permissions",
        ]
        for name in PermissionName.allCases {
            lines.append("  \(name.rawValue): \(snapshot.permissions[name]?.rawValue ?? PermissionState.notDetermined.rawValue)")
        }
        lines += ["", "Settings", "  retention: \(snapshot.retention.rawValue)", "  imageBudget: \(snapshot.imageBudget.rawValue)"]
        for key in snapshot.toggles.keys.sorted() {
            lines.append("  \(key): \(snapshot.toggles[key] == true ? "on" : "off")")
        }
        lines += ["", "Items"]
        for kind in ItemKind.allCases {
            lines.append("  \(kind.rawValue): \(snapshot.itemCounts[kind] ?? 0)")
        }
        lines += [
            "",
            "Storage",
            "  database bytes: \(snapshot.databaseBytes)",
            "  blob bytes: \(snapshot.blobBytes)",
            "",
            "Recent errors (\(snapshot.recentErrors.count), oldest first)",
        ]
        for entry in snapshot.recentErrors {
            lines.append("  \(time.string(from: entry.timestamp)) \(entry.severity.rawValue) \(entry.code.rawValue)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Puts the report on the pasteboard marked as Flotsam's own write so capture does not store it (FR-000-14,
/// FR-001-03). User-initiated only; nothing here sends the report anywhere.
///
/// The marker type identifiers are a parameter because FR-001-03 owns them in the Paste module, which sits above
/// Base. Writing them again here would give one rule two homes; the app passes the Paste constants.
@MainActor
public struct DiagnosticsCopier {
    private let pasteboard: any PasteboardPort
    private let ownWriteTypes: [String]

    public init(pasteboard: any PasteboardPort, ownWriteTypes: [String]) {
        self.pasteboard = pasteboard
        self.ownWriteTypes = ownWriteTypes
    }

    /// Returns the resulting `changeCount` so the caller can record it as an own write (FR-001-03).
    public func copy(_ report: String) -> FlotsamResult<Int> {
        let text = PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data(report.utf8))
        let markers = ownWriteTypes.map { PasteboardRepresentation(uti: $0, data: Data()) }
        return pasteboard.write([text] + markers)
    }
}
