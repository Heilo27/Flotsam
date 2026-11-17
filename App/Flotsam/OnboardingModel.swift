import FlotsamBase
import Foundation
import Observation

/// State behind the onboarding window (FR-008-12). Navigation is `OnboardingFlow`; this holds what the controls on
/// each step show and applies only what that step's own control set: Skip changes nothing, and closing the window
/// part-way leaves nothing half-applied.
@MainActor
@Observable
final class OnboardingModel {
    private(set) var flow: OnboardingFlow
    private(set) var accessibilityGranted = false
    private(set) var inputMonitoringGranted = false
    private(set) var pasteboardAllowed = false
    private(set) var loginStatus: LoginItemStatus = .off
    private(set) var folderName: String?
    private(set) var folderErrorKey: String?
    var pickUpScreenshots: Bool
    var importRecent = true
    var launchAtLogin = true

    @ObservationIgnored private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        flow = OnboardingFlow(gatesPasteboard: PasteboardAccess.isGated)
        pickUpScreenshots = container.settings.value(SettingKeys.screenshotsEnabled)
        refresh()
    }

    var step: OnboardingStep { flow.current }
    var openLibraryChord: ChordBinding { container.settings.value(SettingKeys.shortcutsOpenLibrary) }
    var canOpenLibrary: Bool { container.actions.openLibrary != nil }

    /// Permission state is read fresh each time (FR-008-13 rule b); the view calls this on a 2 s tick and on activation.
    func refresh() {
        accessibilityGranted = container.permissions.isGranted(.accessibility)
        inputMonitoringGranted = container.permissions.isGranted(.inputMonitoring)
        pasteboardAllowed = PasteboardAccess.isAllowed
        loginStatus = container.loginItem.status
        folderName = Pickers.folderName(of: container.settings.value(SettingKeys.screenshotsFolderOverride))
    }

    // MARK: Navigation

    func back() { flow.back() }

    /// Skip leaves the step's setting alone.
    func skip() { flow.advance() }

    /// Continue applies what this step's controls hold, then moves on.
    func continueFromStep() {
        switch step {
        case .screenshots: applyScreenshots()
        case .loginItem: applyLoginItem()
        default: break
        }
        flow.advance()
    }

    // MARK: Step actions

    func allowAccessibility() { container.permissions.request(.accessibility) }
    func allowInputMonitoring() { container.permissions.request(.inputMonitoring) }
    func openSettings(for kind: PermissionKind) { container.permissions.openSystemSettings(kind) }
    func openPasteboardSettings() { PasteboardAccess.openSystemSettings() }
    func openLoginItemsSettings() { container.loginItem.openLoginItemsSettings() }

    func chooseFolder() {
        guard let result = Pickers.chooseScreenshotFolder() else { return }
        switch result {
        case .success(let override):
            container.settings.set(override, for: SettingKeys.screenshotsFolderOverride)
            folderErrorKey = nil
            refresh()
        case .failure(let error):
            folderErrorKey = "error.\(error.code.rawValue)"
        }
    }

    func openLibrary() { container.actions.openLibrary?() }

    /// Closing the window, by any route, counts as finished (FR-008-12).
    func markCompleted() { container.settings.set(true, for: SettingKeys.onboardingCompleted) }

    private func applyScreenshots() {
        container.settings.set(pickUpScreenshots, for: SettingKeys.screenshotsEnabled)
        if pickUpScreenshots && importRecent { container.actions.importRecentScreenshots?() }
    }

    /// The only place onboarding registers the login item, and only on Continue (FR-008-15). A failure shows the HUD
    /// (SET-OS-001) and the switch reverts to what macOS reports.
    private func applyLoginItem() {
        guard launchAtLogin != container.loginItem.isOn else { return }
        if case .failure(let error) = container.loginItem.setEnabled(launchAtLogin) {
            let reporter = container.reporter
            Task { await reporter.report(error, origin: .userInitiated) }
            launchAtLogin = container.loginItem.isOn
        }
        refresh()
    }
}
