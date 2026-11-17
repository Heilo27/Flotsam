import Foundation

/// The seam where the Settings window (FR-008-03) plugs into the menu-bar app. Kept in its own file so the Settings
/// branch replaces only this file: assign `container.actions.openSettings` to a closure that shows (or focuses) the
/// single Settings window. Until then the menu's "Settings…" row stays disabled.
@MainActor
enum SettingsHook {
    static func install(into container: AppContainer) {
        _ = container
    }
}
