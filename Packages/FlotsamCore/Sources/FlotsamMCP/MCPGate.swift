import FlotsamBase
import Foundation

/// The approval gate in front of the MCP server (FR-010-03 to FR-010-06). A client reaches the request handler only
/// through `admit`, and nothing is read from its connection before `admit` says yes.
///
/// Rules, each one a way a hostile or merely noisy local program is kept from turning the prompt into a nuisance or a
/// bypass:
/// - A client approved earlier (its key is in the persisted list) is admitted with no prompt.
/// - An unknown client prompts once. Allow records the approval; Deny is remembered for `denyCooldown`, in memory only,
///   so a client that is refused cannot make the prompt reappear in a loop. The cooldown is not persisted: quitting
///   the app clears it, and the user can always approve a client by retrying after. The owner keeps one gate for the
///   life of the app, so switching the server off and on does not clear it.
/// - Refusals are also counted across all clients: after `lockoutDenials` refusals within `lockoutWindow`, every unknown
///   client is refused without a prompt until the oldest of them ages out. A hostile program that copies itself to a new
///   path for each attempt is a new client each time, so the per-client cooldown alone would let it prompt forever.
/// - Only one prompt is ever open. A second client that connects while one is showing is refused without being
///   remembered (it can retry); a second connection from the same client waits on the same answer.
/// - Approval is read live from the persisted list on every call (`isApproved`), so a revoke takes effect on the next
///   request without the gate holding a copy that could go stale.
public actor MCPGate {
    public enum Admission: Sendable, Equatable {
        case approved
        case denied
    }

    /// Everything the gate needs from outside, so the app supplies settings and the prompt and the gate owns only policy.
    public struct Ports: Sendable {
        /// Is this key in the persisted approvals right now?
        public let isApproved: @Sendable (String) -> Bool
        /// Persists an approval the user just granted. Returns once it is stored, so a client admitted afterwards is
        /// found approved by `isApproved`.
        public let record: @Sendable (MCPApproval) async -> Void
        /// Shows the Allow / Deny prompt and returns the user's answer.
        public let ask: @Sendable (MCPClientIdentity) async -> Bool
        public let now: @Sendable () -> Date

        public init(
            isApproved: @escaping @Sendable (String) -> Bool,
            record: @escaping @Sendable (MCPApproval) async -> Void,
            ask: @escaping @Sendable (MCPClientIdentity) async -> Bool,
            now: @escaping @Sendable () -> Date
        ) {
            self.isApproved = isApproved
            self.record = record
            self.ask = ask
            self.now = now
        }
    }

    /// How long a denied client is refused without a new prompt (FR-010-06).
    public static let denyCooldown: TimeInterval = 300

    /// The refusals that start a global lockout, and the period they are counted over (FR-010-06).
    public static let lockoutDenials = 3
    public static let lockoutWindow: TimeInterval = 600

    private let ports: Ports
    private var deniedUntil: [String: Date] = [:]
    /// When the user answered Don't Allow, oldest first, within `lockoutWindow`.
    private var denials: [Date] = []
    private var pending: (key: String, task: Task<Bool, Never>)?

    public init(ports: Ports) { self.ports = ports }

    public func isApproved(key: String) -> Bool { ports.isApproved(key) }

    public func admit(_ identity: MCPClientIdentity) async -> Admission {
        let key = identity.key
        if ports.isApproved(key) { return .approved }
        let now = ports.now()
        deniedUntil = deniedUntil.filter { $0.value > now }
        denials = denials.filter { $0 > now.addingTimeInterval(-Self.lockoutWindow) }
        if denials.count >= Self.lockoutDenials { return .denied }
        if deniedUntil[key] != nil { return .denied }

        if let pending {
            guard pending.key == key else { return .denied }
            return await pending.task.value ? .approved : .denied
        }

        // The prompt and the recording are one task, so every connection of this client waits for both: none is admitted
        // before the approval is stored.
        let ports = ports
        let task = Task {
            guard await ports.ask(identity) else { return false }
            await ports.record(MCPApproval(key: key, name: identity.name, detail: identity.detail, approvedAt: ports.now()))
            return true
        }
        pending = (key, task)
        let allowed = await task.value
        pending = nil
        if allowed { return .approved }
        let refusedAt = ports.now()
        deniedUntil[key] = refusedAt.addingTimeInterval(Self.denyCooldown)
        denials.append(refusedAt)
        return .denied
    }
}
