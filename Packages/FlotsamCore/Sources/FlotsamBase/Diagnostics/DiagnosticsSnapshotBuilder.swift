import Foundation

/// Facts the diagnostics report needs that only other modules can answer: permission state (Capture, Shortcuts,
/// Screenshots), item counts and file sizes (Storage). Base sits below all of them (ADR-0001), so it asks through
/// this port and each owning module supplies its answer. Every method returns numbers and enum values only, which
/// is what keeps the report free of content (FR-000-10).
public protocol DiagnosticsDataSource: Sendable {
    func permissionStates() async -> [PermissionName: PermissionState]
    /// Live item count per kind.
    func itemCounts() async -> [ItemKind: Int]
    /// Size of the database file and of the blob store, in bytes.
    func storageBytes() async -> (database: Int, blobs: Int)
}

/// Builds the FR-000-14 `DiagnosticsSnapshot` from current state. The one place a snapshot is assembled, so every
/// field the report shows is gathered, and sanitised, here.
///
/// Redaction rules, applied on the way in so `DiagnosticsReport` only ever sees safe values:
/// - settings come from the typed registry (`SettingsStore`), never raw defaults, and only the retention and budget
///   presets are read; no list-valued or free-text setting is reachable from here;
/// - toggle entries are kept only when the key has the registry shape (`group.name`), so a caller cannot smuggle a
///   user-entered string in as a key (the values are already `Bool`);
/// - counts and sizes are clamped to zero or more.
public struct DiagnosticsSnapshotBuilder: Sendable {
    private let environment: DiagnosticsEnvironment
    private let settings: SettingsStore
    private let source: any DiagnosticsDataSource
    private let toggles: @Sendable () -> [String: Bool]
    private let recentErrors: @Sendable () async -> [RaisedError]

    /// - Parameters:
    ///   - toggles: Boolean settings by registry key. The registry holds none yet; FRD-008 supplies them as it adds
    ///     its switches.
    ///   - recentErrors: The ring buffer, normally `reporter.recentErrors`.
    public init(
        environment: DiagnosticsEnvironment = .current,
        settings: SettingsStore,
        source: any DiagnosticsDataSource,
        toggles: @escaping @Sendable () -> [String: Bool] = { [:] },
        recentErrors: @escaping @Sendable () async -> [RaisedError]
    ) {
        self.environment = environment
        self.settings = settings
        self.source = source
        self.toggles = toggles
        self.recentErrors = recentErrors
    }

    /// True for `group.name` keys made of letters and digits, the shape every `SettingKeys` row has.
    static func isRegistryKey(_ key: String) -> Bool {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    }

    public func build() async -> DiagnosticsSnapshot {
        let sizes = await source.storageBytes()
        return DiagnosticsSnapshot(
            environment: environment,
            permissions: await source.permissionStates(),
            retention: settings.value(SettingKeys.storageRetention),
            imageBudget: settings.value(SettingKeys.storageImageBudget),
            toggles: toggles().filter { Self.isRegistryKey($0.key) },
            itemCounts: await source.itemCounts().mapValues { max(0, $0) },
            databaseBytes: max(0, sizes.database),
            blobBytes: max(0, sizes.blobs),
            recentErrors: await recentErrors()
        )
    }

    /// The finished plain-text report for the current state, ready for `DiagnosticsCopier.copy`.
    public func report() async -> String { DiagnosticsReport.render(await build()) }
}
