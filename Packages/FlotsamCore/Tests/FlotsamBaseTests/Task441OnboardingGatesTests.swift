import Testing

@testable import FlotsamBase

// TASK-441, FRD-008 FR-008-12: the two decisions OnboardingModel makes, tested as the pure functions it calls.
// Every case pins one row of the truth table, so flipping either decision turns a case red.

@Suite("TASK-441: onboarding gates")
struct Task441OnboardingGatesTests {
    // OC-8098. Red if the resume rule stops requiring the automatic show, or drops the saved step on it.
    @Test("OC-8098: the automatic show resumes at the saved step", arguments: OnboardingStep.allCases)
    func automaticShowResumes(step: OnboardingStep) {
        #expect(OnboardingFlow.resumeStep(isAutomaticShow: true, saved: step) == step)
    }

    @Test("OC-8098: Show Setup Guide starts over whatever is saved", arguments: OnboardingStep.allCases)
    func manualShowStartsOver(step: OnboardingStep) {
        #expect(OnboardingFlow.resumeStep(isAutomaticShow: false, saved: step) == nil)
    }

    @Test("OC-8098: nothing saved means nothing to resume, on either show")
    func nothingSaved() {
        #expect(OnboardingFlow.resumeStep(isAutomaticShow: true, saved: nil) == nil)
        #expect(OnboardingFlow.resumeStep(isAutomaticShow: false, saved: nil) == nil)
    }

    @Test("OC-8098: the resume rule feeds the flow's starting step")
    func flowStartsWhereRuleSays() {
        let resumed = OnboardingFlow(
            gatesPasteboard: true, resumingAt: OnboardingFlow.resumeStep(isAutomaticShow: true, saved: .hotkey))
        let fresh = OnboardingFlow(
            gatesPasteboard: true, resumingAt: OnboardingFlow.resumeStep(isAutomaticShow: false, saved: .hotkey))
        #expect(resumed.current == .hotkey)
        #expect(fresh.current == .welcome)
    }

    // FR-008-12 step 5. Red if any of the four rows flips.
    @Test("FR-008-12: Continue on step 5 imports only when the box is checked and pickup is on")
    func importTruthTable() {
        #expect(OnboardingFlow.shouldImportScreenshots(importRecent: true, pickupEnabled: true))
        #expect(!OnboardingFlow.shouldImportScreenshots(importRecent: true, pickupEnabled: false))
        #expect(!OnboardingFlow.shouldImportScreenshots(importRecent: false, pickupEnabled: true))
        #expect(!OnboardingFlow.shouldImportScreenshots(importRecent: false, pickupEnabled: false))
    }
}
