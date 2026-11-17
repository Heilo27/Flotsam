/// Every error code in the app (FRD-000 FR-000-03). One enum, one home (ADR-0009).
/// Skeleton seeds three codes; the full catalogue (FRD-000 section 7) is added by the FRD-000 build ticket,
/// each case together with its `error.<code>` catalogue key.
public enum ErrorCode: String, CaseIterable, Sendable {
    case sysInt001 = "SYS-INT-001"
    case stoIo002 = "STO-IO-002"
    case stoDb003 = "STO-DB-003"
    // FRD-007 Storage codes (FRD-000 section 7). Added here so Storage can return them; FRD-000's build owns the rest.
    case stoDb001 = "STO-DB-001"
    case stoDb002 = "STO-DB-002"
    case stoDb004 = "STO-DB-004"
    case stoIo001 = "STO-IO-001"
    case stoIo003 = "STO-IO-003"
    case stoLim001 = "STO-LIM-001"
    case stoLim002 = "STO-LIM-002"
    case stoPol001 = "STO-POL-001"
    // Ingest-limit and validation codes. Ingest picks the one matching the payload's source (FR-007-06).
    case capLim001 = "CAP-LIM-001"
    case capLim002 = "CAP-LIM-002"
    case capLim003 = "CAP-LIM-003"
    case capVal001 = "CAP-VAL-001"
    case sspLim001 = "SSP-LIM-001"
    case sspVal001 = "SSP-VAL-001"
    case shfLim001 = "SHF-LIM-001"

    /// Fixed per code, never caller-supplied (FR-000-01). Fatal is a closed list (FR-000-04).
    public var severity: ErrorSeverity {
        switch self {
        case .stoIo002, .stoDb003: .fatal
        case .sysInt001, .stoDb001, .stoDb002, .stoDb004, .stoIo001: .error
        case .stoLim001, .stoLim002, .capLim001, .capLim003, .sspLim001, .shfLim001: .warning
        case .stoIo003, .stoPol001, .capLim002, .capVal001, .sspVal001: .info
        }
    }

    /// Catalogue key for the user-facing message (FR-000-05). Info codes have no message.
    public var catalogueKey: String { "error.\(rawValue)" }
}

public enum ErrorSeverity: String, Sendable {
    case fatal, error, warning, info
}
