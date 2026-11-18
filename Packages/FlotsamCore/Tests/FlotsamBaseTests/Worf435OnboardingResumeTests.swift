import Foundation
import Testing

@testable import FlotsamBase

// TASK-435, FRD-008 FR-008-12 / AC-008-07 (OC-8098): the onboarding resume point, through the public API only.
// Persistence is always observed through a FRESH UserDefaults reader over the same suite (a relaunch), never an
// in-memory value. The decision "resume only on the automatic launch-time show" is App/Flotsam/OnboardingModel and
// has no package seam; what is pinned here is everything that decision is built from.

/// One UserDefaults suite per test; `launch()` returns a brand-new store and progress reader, like a relaunch.
private struct Relaunchable {
    let name = "worf435-\(UUID().uuidString)"
    func launch() -> (progress: OnboardingProgress, settings: SettingsStore) {
        let raw = UserDefaultsStore(defaults: UserDefaults(suiteName: name)!)
        return (OnboardingProgress(store: raw), SettingsStore(store: raw))
    }
    /// Writes an arbitrary string under the resume key, as a corrupted or foreign value would be.
    func poke(_ value: String) {
        UserDefaults(suiteName: name)!.set(value, forKey: "onboarding.resumeStep")
    }
    func wipe() { UserDefaults().removePersistentDomain(forName: name) }
}

@Suite("TASK-435: onboarding resume point")
struct Worf435OnboardingResumeTests {

    // OC-8098. Red if save/savedStep stop round-tripping through the persisted store (e.g. save becomes a no-op or the
    // key is not written), or the flow ignores the saved step, for ANY step.
    @Test("OC-8098: quitting at each step resumes at that very step (gated Mac)", arguments: OnboardingStep.allCases)
    func resumeAtEveryStepGated(step: OnboardingStep) {
        let r = Relaunchable()
        defer { r.wipe() }
        // given the user reached `step` and the app was quit with command-Q (progress saved, window never closed)
        r.launch().progress.save(step)
        // when relaunched (fresh readers over the same defaults)
        let relaunched = r.launch()
        let flow = OnboardingFlow(gatesPasteboard: true, resumingAt: relaunched.progress.savedStep())
        // then onboarding is still due automatically and it opens on exactly that step
        #expect(OnboardingFlow.shouldShowAutomatically(settings: relaunched.settings))
        #expect(flow.current == step)
        #expect(flow.position == step.rawValue + 1)
        #expect(flow.total == 8)
    }

    // OC-8098. On macOS 14 step 2 does not exist: every other step still resumes in place, position counts out of 7.
    @Test("OC-8098: quitting at each step resumes at that step (ungated Mac, 7 steps)", arguments: OnboardingStep.allCases.filter { $0 != .clipboard })
    func resumeAtEveryStepUngated(step: OnboardingStep) {
        let r = Relaunchable()
        defer { r.wipe() }
        r.launch().progress.save(step)
        let flow = OnboardingFlow(gatesPasteboard: false, resumingAt: r.launch().progress.savedStep())
        #expect(flow.current == step)
        #expect(flow.total == 7)
        #expect(flow.position == (step == .welcome ? 1 : step.rawValue))
    }

    // OC-8098 edge. A step saved on a Mac that gated pasteboard reads, resumed on one that does not (OS change between
    // launches): the hidden step must not strand the flow. Red if resume accepts a step the flow does not show.
    @Test("OC-8098 edge: a saved step 2 on a Mac without step 2 starts at step 1, not on a hidden step")
    func savedHiddenStepStartsAtOne() {
        let r = Relaunchable()
        defer { r.wipe() }
        r.launch().progress.save(.clipboard)
        let flow = OnboardingFlow(gatesPasteboard: false, resumingAt: r.launch().progress.savedStep())
        #expect(flow.current == .welcome)
        #expect(flow.position == 1)
        #expect(flow.steps.contains(flow.current))
    }

    // OC-8098 / FR-008-12 "Show Setup Guide...". Red if the plain initialiser (what Show Setup Guide uses) ever picks
    // up a saved step on its own.
    @Test("FR-008-12: Show Setup Guide starts at step 1 even when a resume point is saved")
    func showSetupGuideStartsAtOne() {
        let r = Relaunchable()
        defer { r.wipe() }
        r.launch().progress.save(.hotkey)
        #expect(r.launch().progress.savedStep() == .hotkey)  // the point is on disk
        for gated in [true, false] {
            let flow = OnboardingFlow(gatesPasteboard: gated)
            #expect(flow.current == .welcome)
            #expect(flow.position == 1)
            #expect(flow.isFirst)
        }
    }

    // OC-8098. Red if a nil / absent resume point stops meaning step 1 (fresh install).
    @Test("OC-8098 edge: nothing saved means step 1 on a fresh install")
    func nothingSavedIsStepOne() {
        let r = Relaunchable()
        defer { r.wipe() }
        let launched = r.launch()
        #expect(launched.progress.savedStep() == nil)
        #expect(OnboardingFlow(gatesPasteboard: true, resumingAt: launched.progress.savedStep()).current == .welcome)
        #expect(OnboardingFlow.shouldShowAutomatically(settings: launched.settings))
    }

    // OC-8098 boundary. Garbage under the key must read as "no resume point" (never crash, never a wrong step).
    // Includes 8 (max+1 over the last raw value 7), -1, empty and non-numeric text.
    @Test("OC-8098 edge: a corrupted resume value is ignored and the flow starts at step 1", arguments: ["", "abc", "8", "99", "-1", "2.5", " 3"])
    func corruptedValueIsIgnored(raw: String) {
        let r = Relaunchable()
        defer { r.wipe() }
        r.poke(raw)
        let progress = r.launch().progress
        #expect(progress.savedStep() == nil)
        #expect(OnboardingFlow(gatesPasteboard: true, resumingAt: progress.savedStep()).current == .welcome)
    }

    // OC-8098 boundary 0 and 7 (first and last raw values): both resume exactly.
    @Test("OC-8098 boundary: raw 0 resumes at Welcome and raw 7 at Done")
    func rawBoundaries() {
        let r = Relaunchable()
        defer { r.wipe() }
        r.poke("0")
        #expect(r.launch().progress.savedStep() == .welcome)
        r.poke("7")
        let flow = OnboardingFlow(gatesPasteboard: true, resumingAt: r.launch().progress.savedStep())
        #expect(flow.current == .done)
        #expect(flow.isLast)
    }

    // OC-8098. Closing the window clears the point (markCompleted calls clear): a later relaunch/Show Setup Guide
    // must not see a stale step. Red if clear() leaves the value in the store.
    @Test("OC-8098: clear removes the resume point for a fresh reader")
    func clearRemovesPoint() {
        let r = Relaunchable()
        defer { r.wipe() }
        r.launch().progress.save(.loginItem)
        #expect(r.launch().progress.savedStep() == .loginItem)
        r.launch().progress.clear()
        #expect(r.launch().progress.savedStep() == nil)
        // and clearing twice / when empty is harmless
        r.launch().progress.clear()
        #expect(r.launch().progress.savedStep() == nil)
    }

    // OC-8098. Saving a later step overwrites an earlier one (Back writes the earlier step too). Red if save appends or
    // keeps the first value.
    @Test("OC-8098: the last move wins, forward and Back")
    func lastMoveWins() {
        let r = Relaunchable()
        defer { r.wipe() }
        let progress = r.launch().progress
        var flow = OnboardingFlow(gatesPasteboard: true)
        var trail: [OnboardingStep] = []
        for _ in 0..<4 { flow.advance(); progress.save(flow.current); trail.append(r.launch().progress.savedStep()!) }
        #expect(trail == [.clipboard, .accessibility, .inputMonitoring, .screenshots])
        flow.back()
        progress.save(flow.current)
        #expect(r.launch().progress.savedStep() == .inputMonitoring)
    }

    // OC-8098. Resume point is progress, not a preference: saving it must NOT mark onboarding finished and must not
    // change any registry default, or a quit would stop onboarding resuming at all (FR-008-12, FR-008-01).
    @Test("OC-8098: saving progress leaves onboarding.completed false and the registry untouched")
    func progressIsNotAPreference() {
        let r = Relaunchable()
        defer { r.wipe() }
        let before = r.launch().settings
        let completedBefore = before.value(SettingKeys.onboardingCompleted)
        r.launch().progress.save(.inputMonitoring)
        let after = r.launch().settings
        #expect(completedBefore == false)
        #expect(after.value(SettingKeys.onboardingCompleted) == false)
        #expect(OnboardingFlow.shouldShowAutomatically(settings: after))
    }

    // OC-8097 x OC-8098. Finished onboarding (window closed => completed true, point cleared) never auto-shows and
    // has nothing to resume. Red if either half of the close handling is lost.
    @Test("OC-8097/8098: after completion neither the automatic show nor a resume point remain")
    func completedAndClearedStaysClosed() {
        let r = Relaunchable()
        defer { r.wipe() }
        let first = r.launch()
        first.progress.save(.done)
        first.settings.set(true, for: SettingKeys.onboardingCompleted)
        first.progress.clear()
        let relaunched = r.launch()
        #expect(!OnboardingFlow.shouldShowAutomatically(settings: relaunched.settings))
        #expect(relaunched.progress.savedStep() == nil)
    }
}
