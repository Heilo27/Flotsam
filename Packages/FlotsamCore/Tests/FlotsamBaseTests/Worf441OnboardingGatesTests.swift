import Foundation
import Testing

@testable import FlotsamBase

// TASK-441 blind QA, FRD-008 FR-008-12 (OC-8098 resume, step 5 import). The two decisions are observed the way the app
// calls them: saved value in a store -> OnboardingProgress.savedStep -> OnboardingFlow.resumeStep -> OnboardingFlow.

@Suite("TASK-441 Worf: onboarding gates")
struct Worf441OnboardingGatesTests {
    private func startStep(automatic: Bool, raw: String?) -> OnboardingStep {
        let store = MemoryKeyValueStore()
        if let raw { store.setString(raw, forKey: "onboarding.resumeStep") }
        let saved = OnboardingProgress(store: store).savedStep()
        return OnboardingFlow(resumingAt: OnboardingFlow.resumeStep(isAutomaticShow: automatic, saved: saved)).current
    }

    // Red if resumeStep ignores isAutomaticShow, or drops/changes the saved step, for any step.
    @Test("OC-8098: every saved step, automatic show resumes there; manual show starts at 1", arguments: OnboardingStep.allCases)
    func everySavedStep(step: OnboardingStep) {
        // given a stored raw step; when launched automatically then manually; then resume vs welcome
        #expect(startStep(automatic: true, raw: String(step.rawValue)) == step)
        #expect(startStep(automatic: false, raw: String(step.rawValue)) == .welcome)
    }

    // Red if corrupt/out-of-range values start resuming somewhere, or crash.
    @Test("OC-8098: corrupt or out-of-range saved value starts at step 1 on either show", arguments: ["", "abc", "-1", "8", "99", "2.5", " 3", "9223372036854775808"])
    func corruptValue(raw: String) {
        #expect(startStep(automatic: true, raw: raw) == .welcome)
        #expect(startStep(automatic: false, raw: raw) == .welcome)
    }

    @Test("OC-8098: nothing saved starts at step 1 on either show")
    func nothingSaved() {
        #expect(startStep(automatic: true, raw: nil) == .welcome)
        #expect(startStep(automatic: false, raw: nil) == .welcome)
    }

    // Red if any of the four rows flips, or the operands are swapped (distinct rows pin each argument).
    @Test("FR-008-12: step 5 import truth table", arguments: [
        (true, true, true), (true, false, false), (false, true, false), (false, false, false),
    ])
    func importTable(row: (Bool, Bool, Bool)) {
        #expect(OnboardingFlow.shouldImportScreenshots(importRecent: row.0, pickupEnabled: row.1) == row.2)
    }

    // Rule 9: the app model holds no second copy of either rule.
    @Test("Rule 9: OnboardingModel calls the rules and has no inline copy")
    func noSecondCopy() throws {
        let code = try frd008Code("App/Flotsam/OnboardingModel.swift")
        #expect(code.contains("OnboardingFlow.resumeStep("))
        #expect(code.contains("OnboardingFlow.shouldImportScreenshots("))
        #expect(!code.contains("resuming ? "))
        #expect(!code.contains("importRecent &&"))
        #expect(!code.contains("&& container.screenshotPickup"))
        // wiring: the inputs are the real ones (resuming flag, saved step, checkbox, live pickup setting)
        #expect(code.contains("isAutomaticShow: resuming, saved: container.onboardingProgress.savedStep()"))
        #expect(code.contains("importRecent: importRecent, pickupEnabled: container.screenshotPickup.enabled"))
    }
}
