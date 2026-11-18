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
    var importRecent = true
    var launchAtLogin = true

    @ObservationIgnored private let container: AppContainer

    /// `resuming` is true only for the automatic launch-time show, which picks up where a quit left off; "Show Setup
    /// Guide…" always starts at step 1 (FR-008-12).
    init(container: AppContainer, resuming: Bool) {
        self.container = container
        flow = OnboardingFlow(
            gatesPasteboard: true,
            resumingAt: OnboardingFlow.resumeStep(isAutomaticShow: resuming, saved: container.onboardingProgress.savedStep()))
        refresh()
    }

    var step: OnboardingStep { flow.current }
    var openLibraryChord: ChordBinding { container.settings.value(SettingKeys.shortcutsOpenLibrary) }
    var canOpenLibrary: Bool { container.actions.openLibrary != nil }

    /// Permission state is read fresh each time (FR-008-13 rule b); the view calls this through `refreshWhileVisible` (on activation and every `VisibleRefresh.interval` while its window is visible).
    func refresh() {
        accessibilityGranted = container.permissions.isGranted(.accessibility)
        inputMonitoringGranted = container.permissions.isGranted(.inputMonitoring)
        pasteboardAllowed = PasteboardAccess.isAllowed
        if OnboardingFlow.readsLoginStatus(on: step) { loginStatus = container.loginItem.status }
        folderName = container.screenshotPickup.folderName
    }

    // MARK: Navigation

    func back() {
        flow.back()
        saveProgress()
        refresh()
    }

    /// Skip leaves the step's setting alone.
    func skip() {
        flow.advance()
        saveProgress()
        refresh()
    }

    /// Continue applies what this step's controls hold, then moves on.
    func continueFromStep() {
        switch step {
        case .screenshots: applyScreenshots()
        case .loginItem: applyLoginItem()
        default: break
        }
        flow.advance()
        saveProgress()
        refresh()
    }

    // MARK: Step actions

    func allowAccessibility() { container.permissions.request(.accessibility) }
    func allowInputMonitoring() { container.permissions.request(.inputMonitoring) }
    func openSettings(for kind: PermissionKind) { container.permissions.openSystemSettings(kind) }
    func openPasteboardSettings() { PasteboardAccess.openSystemSettings() }
    func openLoginItemsSettings() { container.loginItem.openLoginItemsSettings() }

    func openLibrary() { container.actions.openLibrary?() }

    /// Closing the window, by any route, counts as finished (FR-008-12), so the resume point goes with it.
    func markCompleted() {
        container.settings.set(true, for: SettingKeys.onboardingCompleted)
        container.onboardingProgress.clear()
    }

    /// Written on every move, because ⌘Q gives no later moment to write it (FR-008-12).
    private func saveProgress() { container.onboardingProgress.save(flow.current) }

    /// Step 5 changes no setting: pickup and the folder belong to General alone (FR-008-17). The one thing it does is
    /// the optional import of the last 30 days, and only while pickup is on.
    private func applyScreenshots() {
        if OnboardingFlow.shouldImportScreenshots(importRecent: importRecent, pickupEnabled: container.screenshotPickup.enabled) {
            container.actions.importRecentScreenshots?()
        }
    }

    /// The only place onboarding registers the login item, and only on Continue (FR-008-15). A failure shows the HUD
    /// (SET-OS-001) and the switch reverts to what macOS reports.
    private func applyLoginItem() {
        if case .failure(let error) = container.loginItem.reconcile(wanted: launchAtLogin) {
            let reporter = container.reporter
            Task { await reporter.report(error, origin: .userInitiated) }
            launchAtLogin = container.loginItem.isOn
        }
        refresh()
    }
}
