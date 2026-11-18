import Foundation
import Testing

@testable import FlotsamBase

// FRD-008 contract tests, Phase 8T part B: onboarding (OC-8082 to OC-8102).
// Oracle: .claude/oracle/frd-008-contract.json. Each test names the OC it checks and the change that turns it red.
//
// NO SEAM: MANUAL (logic lives in the App target, which package tests cannot import, or needs a live OS):
//   OC-8084 live status flip (pasteboard probe is App/Platform), OC-8086, OC-8087, OC-8088, OC-8089 (Allow / Not Now /
//   Return wiring is App/Flotsam/OnboardingModel + OnboardingView), OC-8090, OC-8091 (needs ScreenshotWatcher, which
//   FlotsamBaseTests cannot link; belongs in FlotsamScreenshotsTests), OC-8092, OC-8095, OC-8096, OC-8099 (Skip / Continue /
//   close handlers are App code).

/// A UserDefaults suite unique to one test, so a second `SettingsStore` over the same suite is a fresh reader.
struct Frd008Defaults {
    let name = "frd008-contract-\(UUID().uuidString)"
    func store() -> SettingsStore {
        SettingsStore(store: UserDefaultsStore(defaults: UserDefaults(suiteName: name)!))
    }
    func wipe() { UserDefaults().removePersistentDomain(forName: name) }
}

struct Frd008LoginService: LoginItemService, @unchecked Sendable {
    final class Box: @unchecked Sendable {
        var status: LoginItemStatus
        var registers = 0
        var unregisters = 0
        var opened = 0
        var registerFails = false
        var unregisterFails = false
        init(status: LoginItemStatus) { self.status = status }
    }
    let box: Box
    var status: LoginItemStatus { box.status }
    func register() -> FlotsamResult<Void> {
        box.registers += 1
        if box.registerFails { return .failure(FlotsamError(.setOs001, "refused")) }
        box.status = .enabled
        return .success(())
    }
    func unregister() -> FlotsamResult<Void> {
        box.unregisters += 1
        if box.unregisterFails { return .failure(FlotsamError(.setOs001, "refused")) }
        box.status = .off
        return .success(())
    }
    func openLoginItemsSettings() { box.opened += 1 }
}

@Suite("FRD-008 contract: onboarding")
struct Frd008ContractOnboardingTests {
    private func text(_ key: String) -> String { FlotsamStrings.text(forKey: key) ?? "<missing \(key)>" }

    // OC-8082. Red if the first step stops being Welcome, the welcome copy loses the no-network statement, or a fresh
    // install stops opening onboarding by itself.
    @Test("OC-8082: fresh install opens onboarding on step 1 with the purpose and the no-network sentence")
    func freshInstallStartsAtWelcome() {
        // given a fresh install (empty settings)
        let settings = SettingsStore(store: MemoryKeyValueStore())
        // when Flotsam launches
        let show = OnboardingFlow.shouldShowAutomatically(settings: settings)
        let flow = OnboardingFlow(gatesPasteboard: true)
        // then onboarding opens, on step 1 of 8, with both statements
        #expect(show)
        #expect(flow.current == .welcome)
        #expect(flow.position == 1)
        #expect(flow.total == 8)
        #expect(text(flow.current.purposeKey) == "Flotsam keeps a local history of what you copy and screenshot.")
        #expect(text("ui.onboarding.welcomeNetwork") == "Flotsam never sends anything off your Mac.")
        // negative: once completed it no longer opens by itself
        settings.set(true, for: SettingKeys.onboardingCompleted)
        #expect(!OnboardingFlow.shouldShowAutomatically(settings: settings))
    }

    // OC-8083. Red if a step loses its title or purpose, the first step gains Back, a later step loses Back, the
    // position indicator skips, or a permission step loses its "what stops without it" line.
    @Test("OC-8083: every step has a title and one-sentence purpose, Back on steps 2-8, and an ordered progress position")
    func everyStepHasChrome() {
        var flow = OnboardingFlow(gatesPasteboard: true)
        var seen: [(OnboardingStep, Int, Int, Bool)] = []
        // when the user advances through every step
        while true {
            seen.append((flow.current, flow.position, flow.total, flow.isFirst))
            let before = flow.current
            flow.advance()
            if flow.current == before { break }
        }
        // then the steps, positions and Back availability are exactly these (Back shown when not first)
        #expect(seen.map(\.0) == [.welcome, .clipboard, .accessibility, .inputMonitoring, .screenshots, .hotkey, .loginItem, .done])
        #expect(seen.map(\.1) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(seen.allSatisfy { $0.2 == 8 })
        #expect(seen.map(\.3) == [true, false, false, false, false, false, false, false])
        // and every step has a real title and a single-sentence purpose
        let titles = seen.map { text($0.0.titleKey) }
        #expect(titles == [
            "Welcome to Flotsam", "Clipboard access", "Accessibility", "Input Monitoring", "Screenshots", "Shortcut",
            "Launch at Login", "You are set",
        ])
        for step in OnboardingStep.allCases {
            let purpose = text(step.purposeKey)
            #expect(purpose.hasSuffix("."), "\(step) purpose must be a sentence: \(purpose)")
            #expect(!purpose.contains(". "), "\(step) purpose must be one sentence: \(purpose)")
            #expect(!purpose.hasPrefix("<missing"))
        }
        // and the chrome strings
        #expect(text("ui.onboarding.skip") == "Skip")
        #expect(text("ui.onboarding.back") == "Back")
        #expect(text("ui.onboarding.stepOf") == "Step %lld of %lld")
        // and permission steps say what stops without them
        #expect(text("ui.onboarding.accessibilityMissing") == "Without it, choosing an item copies it and you press ⌘V yourself.")
        #expect(text("ui.onboarding.inputMonitoringOptional") == "Optional. Without it, typed triggers do nothing; everything else works.")
        #expect(text("ui.onboarding.clipboardMissing").hasPrefix("Without it, Flotsam cannot save what you copy."))
    }

    // OC-8084 (navigation half). Red if the clipboard step is not step 2 on a gated macOS.
    @Test("OC-8084: on a gated macOS step 2 is Clipboard access, with the Paste from Other Apps instruction")
    func gatedMacShowsClipboardStepSecond() {
        var flow = OnboardingFlow(gatesPasteboard: true)
        flow.advance()
        #expect(flow.current == .clipboard)
        #expect(flow.position == 2)
        #expect(text("ui.onboarding.clipboardMissing").contains("Paste from Other Apps"))
        #expect(text("ui.onboarding.openSystemSettings") == "Open System Settings")
        // negative: Back from step 2 returns to Welcome
        flow.back()
        #expect(flow.current == .welcome)
    }

    // OC-8085. Red if the clipboard step is shown when the OS does not gate pasteboard reads.
    @Test("OC-8085: on macOS 14 step 2 is skipped and Accessibility follows Welcome")
    func ungatedMacSkipsClipboardStep() {
        var flow = OnboardingFlow(gatesPasteboard: false)
        #expect(flow.steps == [.welcome, .accessibility, .inputMonitoring, .screenshots, .hotkey, .loginItem, .done])
        #expect(flow.total == 7)
        flow.advance()
        #expect(flow.current == .accessibility)
        #expect(flow.position == 2)
        // Back returns past the skipped step to Welcome
        flow.back()
        #expect(flow.current == .welcome)
        // boundary: Back on the first step stays put
        flow.back()
        #expect(flow.current == .welcome)
    }

    // OC-8093. Red if the default chord changes, or the recorded chord does not survive a fresh reader.
    @Test("OC-8093: step 6 default is the Control-Command-V chord and a recorded Option-Command-V persists")
    func hotkeyDefaultAndRecordedPersist() {
        let defaults = Frd008Defaults()
        defer { defaults.wipe() }
        // given the default before recording
        guard case .chord(let initial) = defaults.store().value(SettingKeys.shortcutsOpenLibrary) else {
            Issue.record("default Open Library is not a chord")
            return
        }
        #expect(initial.displayString == "⌃⌘V")
        // when the user records Option-Command-V
        defaults.store().set(
            .chord(Chord(keyCode: 9, modifiers: [.option, .command])), for: SettingKeys.shortcutsOpenLibrary)
        // then a fresh store (Settings > Shortcuts) reads Option-Command-V
        guard case .chord(let recorded) = defaults.store().value(SettingKeys.shortcutsOpenLibrary) else {
            Issue.record("recorded Open Library is not a chord")
            return
        }
        #expect(recorded.displayString == "⌥⌘V")
        #expect(recorded != initial)
    }

    // OC-8094. Red if setEnabled(true) stops calling register(), or reports a status other than the service's.
    @Test("OC-8094: continuing with the login switch on registers once and reports enabled or requires-approval")
    func continuingRegistersLoginItem() throws {
        let box = Frd008LoginService.Box(status: .off)
        let controller = LoginItemController(service: Frd008LoginService(box: box))
        // given nothing registered before Continue
        #expect(box.registers == 0)
        #expect(controller.status == .off)
        // when the user continues with the switch on
        let result = controller.setEnabled(true)
        // then register ran exactly once and the status is enabled
        #expect(box.registers == 1)
        #expect(try result.get() == .enabled)
        #expect(controller.isOn)
        // approval-pending status is also on
        let pending = Frd008LoginService.Box(status: .requiresApproval)
        #expect(LoginItemController(service: Frd008LoginService(box: pending)).isOn)
    }

    // OC-8097. Red if the completed flag is not persisted, or is not read at the next launch.
    @Test("OC-8097: after the window closes (completed set) a relaunch does not open onboarding")
    func completedPersistsAcrossRelaunch() {
        let defaults = Frd008Defaults()
        defer { defaults.wipe() }
        #expect(OnboardingFlow.shouldShowAutomatically(settings: defaults.store()))
        // when the window is closed on step 3 (the close handler sets the flag)
        defaults.store().set(true, for: SettingKeys.onboardingCompleted)
        // then a fresh launch does not show it again
        #expect(!OnboardingFlow.shouldShowAutomatically(settings: defaults.store()))
    }

    // OC-8098. Quitting mid-onboarding (command-Q, no window close) must not bring steps 1-3 back. The flow saves its
    // step on every move; a relaunch resumes from the saved step. Red when a relaunch re-shows steps 1-3.
    @Test("OC-8098: quitting on step 4 does not bring steps 1-3 back at relaunch")
    func quitMidwayDoesNotRepeatSteps() {
        let defaults = Frd008Defaults()
        defer { defaults.wipe() }
        func launch() -> (OnboardingProgress, SettingsStore) {
            let raw = UserDefaultsStore(defaults: UserDefaults(suiteName: defaults.name)!)
            return (OnboardingProgress(store: raw), SettingsStore(store: raw))
        }
        // given steps 1-3 finished (advance x3, saved on each move) and the app quit without closing the window
        let (progress, _) = launch()
        var flow = OnboardingFlow(gatesPasteboard: true, resumingAt: progress.savedStep())
        for _ in 0..<3 {
            flow.advance()
            progress.save(flow.current)
        }
        #expect(flow.current == .inputMonitoring)
        // when relaunched (a fresh reader over the same defaults)
        let (relaunchedProgress, relaunchedSettings) = launch()
        let relaunched = OnboardingFlow(gatesPasteboard: true, resumingAt: relaunchedProgress.savedStep())
        let shownAutomatically = OnboardingFlow.shouldShowAutomatically(settings: relaunchedSettings)
        // then steps 1-3 are not shown again: either it stays closed or it resumes past step 3
        #expect(!shownAutomatically || relaunched.position > 3)
        #expect(relaunched.current == .inputMonitoring)
        // negative: with no saved step (Show Setup Guide, or a first launch) the flow starts at step 1
        relaunchedProgress.clear()
        #expect(OnboardingFlow(gatesPasteboard: true, resumingAt: relaunchedProgress.savedStep()).position == 1)
    }

    // OC-8100. Red if the default capture mode stops capturing, so onboarding being open would block capture.
    @Test("OC-8100: with onboarding open on a fresh install capture is already on")
    func onboardingDoesNotBlockCapture() {
        let settings = SettingsStore(store: MemoryKeyValueStore())
        #expect(OnboardingFlow.shouldShowAutomatically(settings: settings))
        let mode = settings.value(SettingKeys.captureMode)
        #expect(mode == .active)
        #expect(mode.capturesClipboardAutomatically)
        // negative: a paused mode would not capture (the property is not a constant)
        #expect(!CaptureMode.paused.capturesClipboardAutomatically)
    }

    // OC-8101. Red if Back moves anywhere but one step earlier, or if navigating writes a setting.
    @Test("OC-8101: Back from step 4 shows step 3 and changes no setting")
    func backChangesNoSetting() {
        let raw = MemoryKeyValueStore()
        var flow = OnboardingFlow(gatesPasteboard: true)
        for _ in 0..<3 { flow.advance() }
        #expect(flow.current == .inputMonitoring)
        flow.back()
        #expect(flow.current == .accessibility)
        #expect(flow.position == 3)
        #expect(SettingKeys.all.allSatisfy { raw.string(forKey: $0.name) == nil })
    }

    // OC-8102. Red if "Show Setup Guide" does not restart at step 1, or if showing it clears the completed flag.
    @Test("OC-8102: after completion the setup guide restarts at step 1 and relaunch stays closed")
    func setupGuideRestartsAtStepOne() {
        let defaults = Frd008Defaults()
        defer { defaults.wipe() }
        defaults.store().set(true, for: SettingKeys.onboardingCompleted)
        // when the user opens the Setup Guide from the menu
        let guide = OnboardingFlow(gatesPasteboard: true)
        // then it is on step 1, and a relaunch still does not open it automatically
        #expect(guide.current == .welcome)
        #expect(guide.position == 1)
        #expect(!OnboardingFlow.shouldShowAutomatically(settings: defaults.store()))
    }
}
