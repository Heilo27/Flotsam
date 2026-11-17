import Foundation

/// The two permissions Flotsam asks the system for and can test directly (FR-008-13). Pasteboard access and folder
/// access are read where they are used (FRD-001, FRD-002).
public enum PermissionKind: Sendable, CaseIterable {
    case accessibility
    case inputMonitoring
}

/// Reads and requests permissions. State is read fresh on every call and never cached (FR-008-13 rule b).
public protocol PermissionProbe: Sendable {
    func isGranted(_ kind: PermissionKind) -> Bool
    /// Shows the system prompt where the system has one. Only an explaining step or action may call this (rule a).
    func request(_ kind: PermissionKind)
    /// Opens the matching pane of System Settings.
    func openSystemSettings(_ kind: PermissionKind)
}

/// What choosing a Library item does, given Accessibility (FR-008-14).
public enum PasteOutcome: Equatable, Sendable {
    /// Write to the pasteboard, then synthesise the paste keystroke.
    case paste
    /// Write to the pasteboard only and tell the user (HUD from `SET-PRM-001`); no keystroke.
    case copyOnly(FlotsamError)
}

public enum PasteGate {
    public static func outcome(accessibilityGranted: Bool) -> PasteOutcome {
        accessibilityGranted
            ? .paste : .copyOnly(FlotsamError(.setPrm001, "Accessibility not granted; pasting by copy only"))
    }

    public static func outcome(probe: any PermissionProbe) -> PasteOutcome {
        outcome(accessibilityGranted: probe.isGranted(.accessibility))
    }
}

/// The inline message a Triggers pane shows while triggers are on but a permission is missing (FR-008-06).
public enum TriggerPermissionNotice {
    public static func missing(triggersEnabled: Bool, probe: any PermissionProbe) -> [ErrorCode] {
        guard triggersEnabled else { return [] }
        var codes: [ErrorCode] = []
        if !probe.isGranted(.accessibility) { codes.append(.setPrm001) }
        if !probe.isGranted(.inputMonitoring) { codes.append(.setPrm002) }
        return codes
    }
}
