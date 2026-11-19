import FlotsamBase
import FlotsamMCP
import FlotsamStorage
import Foundation

/// Runs the local MCP server while `mcp.enabled` is on and the database is open (FR-010-01, ADR-0013). It owns the
/// lifecycle only: policy lives in `MCPGate`, protocol in `MCPHandler`, the socket in `MCPSocketServer`.
///
/// Nothing is created, bound or listening while the setting is off, which is the default: no socket file, no queue, no
/// task. Turning the setting off, or quitting, closes every connection and removes the socket file.
@MainActor
final class LocalMCPService {
    private let settings: SettingsStore
    private let dataFolder: URL
    private let report: @MainActor @Sendable (FlotsamError) -> Void
    private var database: FlotsamDatabase?
    private var server: MCPSocketServer?
    private var unsubscribe: (@Sendable () -> Void)?

    init(settings: SettingsStore, dataFolder: URL, report: @escaping @MainActor @Sendable (FlotsamError) -> Void) {
        self.settings = settings
        self.dataFolder = dataFolder
        self.report = report
    }

    /// The database is open: start if the setting is on, and follow the settings from now on.
    func attach(database: FlotsamDatabase) {
        self.database = database
        unsubscribe = settings.subscribe { [weak self] change in
            Task { @MainActor in self?.settingChanged(change.name) }
        }
        reconcile()
    }

    /// Quit: closes connections and removes the socket file.
    func stop() {
        unsubscribe?()
        unsubscribe = nil
        server?.stop()
        server = nil
    }

    private func settingChanged(_ name: String) {
        switch name {
        case SettingKeys.mcpEnabled.name: reconcile()
        // A revoke closes that client's open connections now; the per-request check would end them at their next message.
        case SettingKeys.mcpApprovals.name: server?.revokeUnapproved()
        default: break
        }
    }

    private func reconcile() {
        let wanted = settings.value(SettingKeys.mcpEnabled)
        guard wanted, let database else {
            server?.stop()
            server = nil
            return
        }
        guard server == nil else { return }
        let candidate = makeServer(database: database)
        switch candidate.start() {
        case .success:
            server = candidate
        case .failure(let error):
            // FR-010-02: a switch that is on while nothing listens is a lie. Turn it off and say why.
            settings.set(false, for: SettingKeys.mcpEnabled)
            report(error)
        }
    }

    private func makeServer(database: FlotsamDatabase) -> MCPSocketServer {
        let settings = settings
        let approvals = SettingKeys.mcpApprovals
        let gate = MCPGate(ports: MCPGate.Ports(
            isApproved: { settings.value(approvals).contains(key: $0) },
            // One read-modify-write at a time, on the main actor, so two approvals cannot overwrite each other.
            record: { approval in
                await MainActor.run { settings.set(settings.value(approvals).adding(approval), for: approvals) }
            },
            ask: { client in await MainActor.run { MCPAlerts.approve(client) } },
            now: { Date() }))
        let handler = MCPHandler(
            database: database,
            ignoredApps: { Set(settings.value(SettingKeys.privacyIgnoredApps).identifiers) },
            serverVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        return MCPSocketServer(socketURL: MCPWire.socketURL(inFolder: dataFolder), gate: gate, handler: handler)
    }
}
