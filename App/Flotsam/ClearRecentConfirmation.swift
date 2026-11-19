import AppKit
import FlotsamBase

/// The confirmation for the menu-bar Clear Recent (FR-007-11). It is the Clear History sheet's own model
/// (`ClearHistoryModel`) with an alert in place of the sheet: the same count for the chosen range, the same "can't be
/// undone" text, the same Delete, the same HUD, so the count the user confirms is the count deleted and there is one
/// copy of that logic.
@MainActor
enum ClearRecentConfirmation {
    static func run(_ model: ClearHistoryModel, hud: @MainActor @Sendable (String) -> Void) async {
        await model.refreshPreview()
        // A failed count was reported by the model; it is not an empty range, so nothing more is said.
        if model.countFailed { return }
        guard model.canDelete else {
            hud(SettingsString.clearNothing.text)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = SettingsString.clearRecentTitle.text
        alert.informativeText = [model.range.label.text, model.countText].joined(separator: "\n")
        let delete = alert.addButton(withTitle: SettingsString.clearDelete.text)
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: SettingsString.cancel.text)
        NSApplication.shared.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.delete()
    }
}
