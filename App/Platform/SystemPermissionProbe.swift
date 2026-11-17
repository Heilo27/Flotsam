import AppKit
import ApplicationServices
import CoreGraphics
import FlotsamBase

/// Reads and requests Accessibility and Input Monitoring (FR-008-13). Every call asks the system again; nothing is
/// cached (rule b), and nothing here runs at launch (rule a): `request` is only called from an explaining step or action.
struct SystemPermissionProbe: PermissionProbe {
    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        }
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            // The literal is the value of `kAXTrustedCheckOptionPrompt`, which Swift 6 flags as shared mutable state.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
    }

    func openSystemSettings(_ kind: PermissionKind) {
        let anchor: String
        switch kind {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
