/// Every error code in the app (FRD-000 FR-000-03). One enum, one home (ADR-0009).
/// Skeleton seeds three codes; the full catalogue (FRD-000 section 7) is added by the FRD-000 build ticket,
/// each case together with its `error.<code>` catalogue key.
public enum ErrorCode: String, CaseIterable, Sendable {
    case sysInt001 = "SYS-INT-001"
    case stoIo002 = "STO-IO-002"
    case stoDb003 = "STO-DB-003"

    /// Fixed per code, never caller-supplied (FR-000-01). Fatal is a closed list (FR-000-04).
    public var severity: ErrorSeverity {
        switch self {
        case .stoIo002, .stoDb003: .fatal
        case .sysInt001: .error
        }
    }

    /// Catalogue key for the user-facing message (FR-000-05). Info codes have no message.
    public var catalogueKey: String { "error.\(rawValue)" }
}

public enum ErrorSeverity: String, Sendable {
    case fatal, error, warning, info
}
