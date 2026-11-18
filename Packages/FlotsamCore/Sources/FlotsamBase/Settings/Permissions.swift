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
    public var isAccessibilityTrusted: Bool { PasteGate.isAllowed(probe: self) }
}

/// The one owner of the Accessibility decision and of its `SET-PRM-001` error (FR-008-14, ADR-0005, Rule 9). Every
/// path that needs Accessibility (paste, Shelf, Library, item hotkey, trigger expansion, the Triggers pane notice) asks
/// here; none tests the permission or builds the error itself. The gate only decides; the result of a paste attempt is
/// `FlotsamPaste.PasteOutcome` (a denied attempt is its `.copiedAccessibilityDenied`).
public enum PasteGate {
    /// True when Accessibility is granted, so a paste may post the keystroke; false means copy only. Read fresh from
    /// the probe on every call, never cached (FR-008-13 rule b).
    public static func isAllowed(probe: any PermissionProbe) -> Bool {
        probe.isGranted(.accessibility)
    }

    /// The `SET-PRM-001` error for an attempt that could only copy. `itemId` is log context when the attempt has an item.
    public static func copyOnlyError(itemId: UUID? = nil) -> FlotsamError {
        FlotsamError(
            .setPrm001, "Accessibility not granted; pasting by copy only",
            context: itemId.map { [.itemId: .id($0)] } ?? [:])
    }
}

/// The inline message a Triggers pane shows while triggers are on but a permission is missing (FR-008-06).
public enum TriggerPermissionNotice {
    public static func missing(triggersEnabled: Bool, probe: any PermissionProbe) -> [ErrorCode] {
        guard triggersEnabled else { return [] }
        var codes: [ErrorCode] = []
        if !PasteGate.isAllowed(probe: probe) { codes.append(PasteGate.copyOnlyError().code) }
        if !probe.isGranted(.inputMonitoring) { codes.append(.setPrm002) }
        return codes
    }

    /// The text the Triggers pane shows inline for a code from `missing` (FR-008-06). The one place that maps code to
    /// pane text: Accessibility has its own "triggers are paused" string, so `error.SET-PRM-001` stays the copy-only
    /// HUD text; every other code shows its catalogue message.
    public static func text(for code: ErrorCode) -> String {
        switch code {
        case .setPrm001: SettingsString.triggersAccessibilityPaused.text
        default: FlotsamStrings.message(for: FlotsamError(code, "Permission missing for triggers"))
        }
    }
}
