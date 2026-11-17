import AppKit
import FlotsamBase
import SwiftUI

/// The single Settings window (FR-008-03): created on first use, then raised on every later request. The menu row
/// (Cmd-,) and the Library's "open Settings" effect both reach it through `AppContainer.actions.openSettings`.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Built at first use, not at launch: the database opens asynchronously and the window needs its Storage calls.
    private let makeEnvironment: @MainActor () -> SettingsEnvironment
    private var window: NSWindow?

    init(makeEnvironment: @escaping @MainActor () -> SettingsEnvironment) { self.makeEnvironment = makeEnvironment }

    func openSettings() {
        if window == nil {
            let model = SettingsModel(env: makeEnvironment())
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = SettingsString.window.text
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}

@MainActor
enum SettingsHook {
    /// Returns the controller so the caller retains it for the life of the app.
    static func install(into container: AppContainer, showSetupGuide: @escaping @MainActor @Sendable () -> Void)
        -> SettingsWindowController
    {
        let reporter = container.reporter
        let controller = SettingsWindowController {
            SettingsEnvironment(
                settings: container.settings, login: container.loginItem,
                openLoginItems: { container.loginItem.openLoginItemsSettings() },
                permissions: container.permissions,
                storage: container.database.map(SettingsStorage.init(database:)) ?? .unavailable,
                dataFolder: AppContainer.dataFolder,
                report: { error in Task { await reporter.report(error, origin: .userInitiated) } },
                showSetupGuide: showSetupGuide)
        }
        container.actions.openSettings = { [weak controller] in controller?.openSettings() }
        return controller
    }
}
