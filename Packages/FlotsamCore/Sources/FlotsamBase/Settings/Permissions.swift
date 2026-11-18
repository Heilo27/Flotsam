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

extension PermissionProbe {
    /// The Accessibility question the Library footer asks; answered by `PasteGate`, the one owner of the decision.
    public var isAccessibilityTrusted: Bool { PasteGate.outcome(probe: self) == .paste }
}

/// What choosing a Library item does, given Accessibility (FR-008-14). `FlotsamPaste.PasteOutcome` is the full
/// result of a paste attempt; this is only the Accessibility gate's decision.
public enum PasteGateOutcome: Equatable, Sendable {
    /// Write to the pasteboard, then synthesise the paste keystroke.
    case paste
    /// Write to the pasteboard only and tell the user (HUD from `SET-PRM-001`); no keystroke.
    case copyOnly(FlotsamError)
}

/// The one owner of the Accessibility decision and of its `SET-PRM-001` error (FR-008-14, ADR-0005, Rule 9). Every
/// path that needs Accessibility (paste, Shelf, Library, item hotkey, trigger expansion, the Triggers pane notice) asks
/// here; none tests the permission or builds the error itself.
public enum PasteGate {
    public static func outcome(accessibilityGranted: Bool) -> PasteGateOutcome {
        accessibilityGranted ? .paste : .copyOnly(copyOnlyError())
    }

    /// The `SET-PRM-001` error for an attempt that could only copy. `itemId` is log context when the attempt has an item.
    public static func copyOnlyError(itemId: UUID? = nil) -> FlotsamError {
        FlotsamError(
            .setPrm001, "Accessibility not granted; pasting by copy only",
            context: itemId.map { [.itemId: .id($0)] } ?? [:])
    }

    public static func outcome(probe: any PermissionProbe) -> PasteGateOutcome {
        outcome(accessibilityGranted: probe.isGranted(.accessibility))
    }
}

/// The inline message a Triggers pane shows while triggers are on but a permission is missing (FR-008-06).
public enum TriggerPermissionNotice {
    public static func missing(triggersEnabled: Bool, probe: any PermissionProbe) -> [ErrorCode] {
        guard triggersEnabled else { return [] }
        var codes: [ErrorCode] = []
        if case .copyOnly(let error) = PasteGate.outcome(probe: probe) { codes.append(error.code) }
        if !probe.isGranted(.inputMonitoring) { codes.append(.setPrm002) }
        return codes
    }
}
