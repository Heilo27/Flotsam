/// Module part of a code, `<MOD>-<CAT>-<NNN>` (FR-000-03). Raw value is the code prefix.
///
/// Why an enum and not a string prefix check: the set of modules is closed and mirrors the FRD list, so a typo in a
/// new code (`CPA-IO-001`) is caught by parsing instead of silently becoming a new module.
public enum ErrorModule: String, CaseIterable, Sendable {
    case sys = "SYS"   // core
    case cap = "CAP"   // capture
    case ssp = "SSP"   // screenshot pickup
    case lib = "LIB"   // library
    case org = "ORG"   // organize
    case trg = "TRG"   // shortcuts and triggers
    case shf = "SHF"   // shelf
    case sto = "STO"   // storage and retention
    case set = "SET"   // settings, onboarding, permissions

    /// The log category that carries this module's entries (FR-000-09: one category per module). Deriving it from
    /// the code means a call site cannot log a storage error under `capture`.
    public var logCategory: LogCategory {
        switch self {
        case .sys: .core
        case .cap: .capture
        case .ssp: .screenshots
        case .lib: .library
        case .org: .organize
        case .trg: .triggers
        case .shf: .shelf
        case .sto: .storage
        case .set: .settings
        }
    }
}

/// Category part of a code (FR-000-03). `pol` codes are always Info; `ErrorCode.severity` enforces that.
public enum ErrorCategory: String, CaseIterable, Sendable {
    case prm = "PRM"   // permission
    case io = "IO"     // file or disk
    case db = "DB"     // database
    case val = "VAL"   // validation of user input or external data
    case lim = "LIM"   // size or count limit
    case os = "OS"     // system API failure
    case pol = "POL"   // expected skip by policy
    case dat = "DAT"   // data-state inconsistency
    case int = "INT"   // internal
}

/// The three parts of a code string, parsed once in one place (FR-000-03).
public struct ErrorCodeParts: Sendable, Equatable {
    public let module: ErrorModule
    public let category: ErrorCategory
    /// 1...999, per module and category; never reused or renumbered.
    public let number: Int

    /// Parses `<MOD>-<CAT>-<NNN>`. Returns nil for any other shape, including a number that is not exactly three
    /// digits, so a malformed code is rejected rather than coerced.
    public static func parse(_ raw: String) -> ErrorCodeParts? {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let module = ErrorModule(rawValue: String(parts[0])),
              let category = ErrorCategory(rawValue: String(parts[1])),
              parts[2].count == 3,
              parts[2].allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let number = Int(parts[2]), number >= 1
        else { return nil }
        return ErrorCodeParts(module: module, category: category, number: number)
    }
}

extension ErrorCode {
    /// Parsed parts of this code. Nil only if a case were declared with a malformed raw value, which the catalogue
    /// test (FR-000-07) rejects before it can ship.
    public var parts: ErrorCodeParts? { ErrorCodeParts.parse(rawValue) }

    /// Log category for this code's module; `core` if the code were malformed (see `parts`).
    public var logCategory: LogCategory { parts?.module.logCategory ?? .core }
}
