import AppKit
import FlotsamBase
import FlotsamMCP

/// The two modal questions of local AI access (FRD-010): "turn it on?" and "let this AI app in?". All wording is in the
/// String Catalogue; the enable warning is `mcpEnableTitle` / `mcpEnableBody` / `mcpTurnOn` and nowhere else.
@MainActor
enum MCPAlerts {
    /// FR-010-02: the cloud warning shown before the switch turns on. True only for Turn On; Cancel is the default so a
    /// stray Return leaves it off.
    static func confirmEnable() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = SettingsString.mcpEnableTitle.text
        alert.informativeText = SettingsString.mcpEnableBody.text
        alert.addButton(withTitle: SettingsString.cancel.text)
        alert.addButton(withTitle: SettingsString.mcpTurnOn.text)
        NSApplication.shared.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// FR-010-04: the first connection of an unknown AI app. What identifies it (its signature, or its path when unsigned)
    /// comes first, because that is the system's fact about the connecting program; the app's own name is second and
    /// labelled, because an app bundle chooses its name and any program can pick a trusted-looking one. Don't Allow is
    /// the default button, so a stray Return or a click-through does not grant access.
    static func approve(_ client: MCPClientIdentity) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = SettingsString.mcpApproveTitle.text
        alert.informativeText = [client.detail, SettingsString.mcpApproveName.text + " " + client.name, "", SettingsString.mcpApproveBody.text]
            .joined(separator: "\n")
        alert.addButton(withTitle: SettingsString.mcpDeny.text)
        alert.addButton(withTitle: SettingsString.mcpAllow.text)
        NSApplication.shared.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }
}
