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
        // The setup guide is a Flotsam window too: "Show Setup Guide…" in the menu bar and the General pane's button hide
        // the Library before it comes forward (FR-003-02, TASK-524). The launch-time `show(resuming:)` below does not
        // need it: the Library cannot be open before the first window of a launch.
        let showSetupGuide: @MainActor @Sendable () -> Void = { [weak container] in
            container?.hideLibraryBeforeWindowOpens()
            onboarding.show()
        }
        container.installSettings(showSetupGuide: showSetupGuide)
        statusItem = StatusItemController(container: container, showSetupGuide: showSetupGuide)
        // First launch only; afterwards "Show Setup Guide…" is the way in (FR-008-12). No permission is requested
        // here: each step asks for its own, when the user presses its button (FR-008-13 rule a).
        if OnboardingFlow.shouldShowAutomatically(settings: container.settings) { onboarding.show(resuming: true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        container?.stopTriggers()
        container?.stopMaintenance()
        container?.stopLocalMCP()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
