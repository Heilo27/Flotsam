import AppKit
import FlotsamBase

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer?
    private var statusItem: StatusItemController?
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Text fields get ⌘A ⌘C ⌘V ⌘X ⌘Z only through a main menu's key equivalents (FR-008-19).
        NSApp.mainMenu = MainMenuBuilder.make()
        let container = AppContainer()
        self.container = container
        let onboarding = OnboardingWindowController(container: container)
        self.onboarding = onboarding
        container.installSettings(showSetupGuide: { onboarding.show() })
        statusItem = StatusItemController(container: container, showSetupGuide: { onboarding.show() })
        // First launch only; afterwards "Show Setup Guide…" is the way in (FR-008-12). No permission is requested
        // here: each step asks for its own, when the user presses its button (FR-008-13 rule a).
        if OnboardingFlow.shouldShowAutomatically(settings: container.settings) { onboarding.show(resuming: true) }
    }

    func applicationWillTerminate(_ notification: Notification) { container?.stopTriggers() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
