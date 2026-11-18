import Foundation
import Testing
@testable import FlotsamBase

// FRD-007 8T contract tests, slice S1 (Base half): what a fresh install's Settings > Storage popups show and offer.
// The popups themselves are App-target SwiftUI (no test target, see Gaps); what they render is `SettingsStore`'s
// default and the enums' `allCases` + `label` + `caption`, which is asserted here against literals through a fresh,
// empty key-value store.

@Suite struct FRD007ContractSettingsTests {
    private func fresh() -> SettingsStore { SettingsStore(store: MemoryKeyValueStore()) }

    /// OC-7065. Fresh install: budget 2 GB with 4 options, quality Original with 3 options, each with a caption.
    /// Red if a default changes, an option is added, dropped or reordered, or two qualities share a caption.
    @Test("OC-7065 a fresh install shows 2 GB and Original, with exactly four budget and three quality options and captions")
    func oc7065_budgetAndQualityDefaultsAndOptions() {
        // given a fresh install (empty store)
        let settings = fresh()

        // when the Storage pane reads its values and option lists
        // then the popups show 2 GB and Original and offer exactly these
        #expect(settings.value(SettingKeys.storageImageBudget).label.text == "2 GB")
        #expect(settings.value(SettingKeys.storageImageQuality).label.text == "Original")
        #expect(ImageBudget.allCases.map { $0.label.text } == ["500 MB", "2 GB", "10 GB", "Unlimited"])
        #expect(ImageQuality.allCases.map { $0.label.text } == ["Original", "Balanced", "Efficient"])
        // and each quality has its own caption, which is more than its name
        let captions = ImageQuality.allCases.map { $0.caption.text }
        #expect(Set(captions).count == 3)
        #expect(captions.allSatisfy { $0.count > 15 })
        #expect(zip(captions, ImageQuality.allCases.map { $0.label.text }).allSatisfy { $0 != $1 })
    }

    /// OC-7085. Fresh install: Keep history for shows 30 days among exactly five options.
    /// Red if the default is not 30 days or the list changes.
    @Test("OC-7085 a fresh install keeps history for 30 days and offers exactly 7 days, 30 days, 90 days, 1 year, Forever")
    func oc7085_retentionDefaultAndOptions() {
        // given a fresh install
        // when Keep history for is read
        // then it shows 30 days among the five presets
        #expect(fresh().value(SettingKeys.storageRetention).label.text == "30 days")
        #expect(RetentionPreset.allCases.map { $0.label.text } == ["7 days", "30 days", "90 days", "1 year", "Forever"])
    }

    /// OC-7109. Fresh install: capture mode Active among Active, Paused, Curated, each with a caption.
    /// Red if the default changes (a fresh install must record), the list changes, or captions collapse together.
    @Test("OC-7109 a fresh install is in Active capture mode and offers exactly Active, Paused, Curated, each with a caption")
    func oc7109_captureModeDefaultAndOptions() {
        // given a fresh install
        // when the capture mode control reads its value and options
        // then Active is selected among exactly three modes
        #expect(fresh().value(SettingKeys.captureMode).label.text == "Active")
        #expect(CaptureMode.allCases.map { $0.label.text } == ["Active", "Paused", "Curated"])
        // and each carries a distinct caption longer than its name
        let captions = CaptureMode.allCases.map { $0.caption.text }
        #expect(Set(captions).count == 3)
        #expect(captions.allSatisfy { $0.count > 15 })
        #expect(zip(captions, CaptureMode.allCases.map { $0.label.text }).allSatisfy { $0 != $1 })
    }
}
