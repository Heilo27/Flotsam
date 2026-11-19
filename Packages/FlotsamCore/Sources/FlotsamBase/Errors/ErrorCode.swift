/// Every error code in the app (FRD-000 FR-000-03, section 7). One enum, one home (ADR-0009).
///
/// Why a closed enum with the code string as raw value: a code is an identity that appears in logs, Notices and
/// bug reports, so it must be greppable, never reused and never typed as a loose string. A code is added in the
/// same commit as the first call site that raises it, together with its `error.<code>` catalogue entry
/// (FRD-000 section 5); retired codes stay here marked `retired` in FRD section 7 and are never renumbered.
public enum ErrorCode: String, CaseIterable, Sendable {
    // MARK: SYS, core

    /// Propagate, HUD.
    case sysInt001 = "SYS-INT-001"

    // MARK: CAP, capture (FRD-001)

    /// Capture suspended; Notice; retry on app activation.
    case capPrm001 = "CAP-PRM-001"
    /// Skip tick, retry next poll.
    case capOs001 = "CAP-OS-001"
    /// Source app recorded as Unknown.
    case capOs002 = "CAP-OS-002"
    /// Skipped: concealed, transient or auto-generated pasteboard marker.
    case capPol001 = "CAP-POL-001"
    /// Skipped: source app is on the ignored list.
    case capPol002 = "CAP-POL-002"
    /// Skipped: capture paused, or curated mode without explicit save.
    case capPol003 = "CAP-POL-003"
    /// Skipped: Flotsam's own pasteboard write.
    case capPol004 = "CAP-POL-004"
    /// Skipped: empty, whitespace-only, or unsupported payload.
    case capVal001 = "CAP-VAL-001"
    /// Skipped: copied file no longer exists.
    case capDat001 = "CAP-DAT-001"
    /// Skip item; Notice.
    case capLim001 = "CAP-LIM-001"
    /// Rich representation dropped, plain text kept.
    case capLim002 = "CAP-LIM-002"
    /// Keep the first `BundleLimits.maxMembers`; Notice.
    case capLim003 = "CAP-LIM-003"
    /// Item not stored; Notice.
    case capIo001 = "CAP-IO-001"

    // MARK: SSP, screenshot pickup (FRD-002)

    /// Pickup idle; retry every 30 s and on activation.
    case sspPrm001 = "SSP-PRM-001"
    /// Fall back to ~/Desktop.
    case sspIo001 = "SSP-IO-001"
    /// File unstable or unreadable within 5 s; skipped.
    case sspIo002 = "SSP-IO-002"
    /// Paused until folder returns.
    case sspIo003 = "SSP-IO-003"
    /// Not a decodable image; skipped.
    case sspVal001 = "SSP-VAL-001"
    /// Skip file; Notice.
    case sspLim001 = "SSP-LIM-001"
    /// Directory poll fallback.
    case sspOs001 = "SSP-OS-001"

    // MARK: LIB, library (FRD-003)

    /// Item left on pasteboard; HUD.
    case libOs001 = "LIB-OS-001"
    /// Delete item; HUD.
    case libIo001 = "LIB-IO-001"
    /// No paste; HUD; row marked Missing.
    case libDat001 = "LIB-DAT-001"
    /// Secure item not copied: the user cancelled or failed the device-owner check; no pasteboard write; HUD.
    case libOs002 = "LIB-OS-002"
    /// Secure item unavailable: its Keychain key is missing or unreadable, or the stored ciphertext does not open; HUD.
    case libDat002 = "LIB-DAT-002"

    // MARK: ORG, organize (FRD-004)

    /// Edit rejected inline.
    case orgVal001 = "ORG-VAL-001"
    /// Edit rejected inline.
    case orgVal002 = "ORG-VAL-002"
    /// Edit rejected.
    case orgVal003 = "ORG-VAL-003"
    /// Assignment rejected.
    case orgLim001 = "ORG-LIM-001"
    /// Creation rejected.
    case orgLim002 = "ORG-LIM-002"
    /// Edit rejected inline.
    case orgLim003 = "ORG-LIM-003"

    // MARK: TRG, shortcuts and triggers (FRD-005)

    /// Rejected inline.
    case trgVal001 = "TRG-VAL-001"
    /// Rejected inline.
    case trgVal002 = "TRG-VAL-002"
    /// Rejected inline.
    case trgVal003 = "TRG-VAL-003"
    /// Rejected inline.
    case trgVal004 = "TRG-VAL-004"
    /// Saved; inline notice.
    case trgVal005 = "TRG-VAL-005"
    /// A secure item cannot carry a hotkey or a trigger; rejected inline.
    case trgVal006 = "TRG-VAL-006"
    /// Not registered; kept for retry.
    case trgOs001 = "TRG-OS-001"
    /// Abort expansion; HUD.
    case trgOs002 = "TRG-OS-002"
    /// Re-enable tap; Notice.
    case trgOs003 = "TRG-OS-003"
    /// Expansion suppressed: secure input active.
    case trgPol001 = "TRG-POL-001"
    /// Expansion suppressed: frontmost app excluded.
    case trgPol002 = "TRG-POL-002"

    // MARK: SHF, shelf (FRD-006)

    /// Cancel drag; HUD.
    case shfOs001 = "SHF-OS-001"
    /// Skip file; HUD.
    case shfIo001 = "SHF-IO-001"
    /// Skip item; HUD.
    case shfLim001 = "SHF-LIM-001"
    /// Reject drop; HUD.
    case shfVal001 = "SHF-VAL-001"

    // MARK: STO, storage and retention (FRD-007)

    /// Roll back; surface per FR-000-08.
    case stoDb001 = "STO-DB-001"
    /// Move aside, recreate; Notice.
    case stoDb002 = "STO-DB-002"
    /// Alert, quit.
    case stoDb003 = "STO-DB-003"
    /// Propagate.
    case stoDb004 = "STO-DB-004"
    /// Operation aborted.
    case stoIo001 = "STO-IO-001"
    /// Alert, quit.
    case stoIo002 = "STO-IO-002"
    /// Orphan blob or missing blob found during reconcile; repaired.
    case stoIo003 = "STO-IO-003"
    /// No eviction of exempt items; Notice.
    case stoLim001 = "STO-LIM-001"
    /// Skip image ingest; Notice.
    case stoLim002 = "STO-LIM-002"
    /// Retention or budget sweep removed rows (counts logged).
    case stoPol001 = "STO-POL-001"

    // MARK: SET, settings, onboarding, permissions (FRD-008)

    /// Copy-only fallback.
    case setPrm001 = "SET-PRM-001"
    /// Triggers inert.
    case setPrm002 = "SET-PRM-002"
    /// Revert toggle; HUD.
    case setOs001 = "SET-OS-001"
    /// Rejected.
    case setVal001 = "SET-VAL-001"
    /// Rejected.
    case setVal002 = "SET-VAL-002"
    /// Reset; Notice.
    case setDat001 = "SET-DAT-001"

    /// Fixed per code, never caller-supplied (FR-000-01), so one failure cannot be Fatal at one call site and a
    /// Warning at another. The switch is exhaustive with no `default` on purpose: adding a code without deciding
    /// its severity must not compile. Fatal is a closed list of exactly two codes (FR-000-04); every `POL`
    /// category code is Info (FR-000-03).
    public var severity: ErrorSeverity {
        switch self {
        case .stoDb003, .stoIo002:
            .fatal
        case .sysInt001, .capIo001, .libOs001, .libIo001, .orgVal001, .orgVal002, .orgVal003,
             .orgLim001, .orgLim002, .orgLim003, .trgVal001, .trgVal002, .trgVal003, .trgVal004,
             .trgOs001, .trgOs002, .trgVal006, .shfOs001, .stoDb001, .stoDb002, .stoDb004, .stoIo001, .setOs001,
             .setVal001, .setVal002:
            .error
        case .capPrm001, .capOs001, .capLim001, .capLim003, .sspPrm001, .sspIo001, .sspIo003, .sspLim001,
             .sspOs001, .libDat001, .libOs002, .libDat002, .trgVal005, .trgOs003, .shfIo001, .shfLim001, .shfVal001, .stoLim001,
             .stoLim002, .setPrm001, .setPrm002, .setDat001:
            .warning
        case .capOs002, .capPol001, .capPol002, .capPol003, .capPol004, .capVal001, .capDat001, .capLim002,
             .sspIo002, .sspVal001, .trgPol001, .trgPol002, .stoIo003, .stoPol001:
            .info
        }
    }

    /// Catalogue key for the user-facing message (FR-000-05). Info codes have no message.
    public var catalogueKey: String { "error.\(rawValue)" }
}

/// Fatal, Error, Warning, Info (FR-000-04). The raw value is the log-level family name used in reports.
public enum ErrorSeverity: String, Sendable {
    case fatal, error, warning, info
}

extension ErrorCode {
    /// The argument kinds this code's catalogue message takes, in placeholder order (FR-000-05). The one declaration
    /// of which codes carry placeholders; `FlotsamStrings.argumentKindViolations` fails if it drifts from the
    /// catalogue, so a mismatch is caught by the consistency check and never reaches `String(format:)` at runtime.
    public var messageArgumentKinds: [MessageArgumentKind] {
        switch self {
        case .capLim001, .orgLim003, .shfLim001, .sspLim001: [.text]
        case .capLim003: [.integer]
        default: []
        }
    }
}
