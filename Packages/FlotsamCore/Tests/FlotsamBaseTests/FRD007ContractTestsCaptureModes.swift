import Foundation
import Testing
@testable import FlotsamBase

// FRD-007 8T contract tests, slice S2 (Base half): what the capture mode persists and what the menu offers
// (OC-7105, OC-7108). The mode's effect on the clipboard poll, screenshot pickup and the Shelf is in the Capture,
// Screenshots and Shelf test targets (same file name, same OC ids). Menu-bar icon drawing and the menu's AppKit
// rendering are App-target (see FRD007ContractTestsGaps.swift).

@Suite struct FRD007ContractCaptureModeTests {
    /// OC-7105. Paused survives quit and relaunch: a second SettingsStore over the same persisted store (the relaunch)
    /// reads Paused, the control shows Paused, the icon and the menu show the paused state, and the mode no longer
    /// captures on its own. Red if `capture.mode` stops being persisted, loads as Active, or the icon or menu ignores it.
    @Test("OC-7105 Paused persists across relaunch: control, icon label and menu item all show it and nothing captures")
    func oc7105_pausedSurvivesRelaunch() {
        // given Paused set in one launch of the app
        let disk = MemoryKeyValueStore()
        SettingsStore(store: disk).set(CaptureMode.paused, for: SettingKeys.captureMode)

        // when Flotsam is relaunched (a fresh SettingsStore over the same persisted values)
        let relaunched = SettingsStore(store: disk)
        let mode = relaunched.value(SettingKeys.captureMode)

        // then the Storage control shows Paused
        #expect(mode == .paused)
        #expect(mode.label.text == "Paused")
        // and the icon is the paused one with a paused accessibility label, different from the active one
        let keys = MenuBarModel.icon(mode: mode, hasWarning: false).accessibilityKeys
        #expect(keys == ["ui.menu.iconPaused"])
        let label = FlotsamStrings.text(forKey: keys[0]) ?? ""
        #expect(label.lowercased().contains("paused"))
        #expect(label != FlotsamStrings.text(forKey: "ui.menu.iconActive"))
        // and the menu shows Resume Capture, and no Pause Capture
        let rows = MenuBarModel.entries(settings: relaunched)
        #expect(rows.contains(.captureToggle(titleKey: "ui.menu.resumeCapture", next: .active)))
        #expect(!rows.contains(.captureToggle(titleKey: "ui.menu.pauseCapture", next: .paused)))
        #expect(FlotsamStrings.text(forKey: "ui.menu.resumeCapture") == "Resume Capture")
        // and copying text still creates no item: the mode does not capture on its own
        #expect(mode.capturesClipboardAutomatically == false)
    }

    /// OC-7105 (control group). Active, the default, survives relaunch as Active and offers Pause Capture, so the test
    /// above is red for the persistence and not because every launch reads Paused.
    /// Red if a fresh launch starts Paused.
    @Test("OC-7105 a store that never held Paused relaunches Active with Pause Capture")
    func oc7105_activeRelaunchesActive() {
        // given an empty persisted store, then a relaunch
        let disk = MemoryKeyValueStore()
        let relaunched = SettingsStore(store: disk)

        // when the mode and the menu are read
        // then Active, with Pause Capture and the active icon
        #expect(relaunched.value(SettingKeys.captureMode) == .active)
        #expect(MenuBarModel.entries(settings: relaunched).contains(.captureToggle(titleKey: "ui.menu.pauseCapture", next: .paused)))
        #expect(MenuBarModel.icon(mode: .active, hasWarning: false).accessibilityKeys == ["ui.menu.iconActive"])
    }

    /// OC-7105 wording. The contract and docs/DESIGN.md name the paused label 'Flotsam, paused'; the shipped catalogue
    /// string `ui.menu.iconPaused` is 'Flotsam, capture paused'. FRD-008 does not fix the wording, so this is a wording
    /// defect against the contract and the design table, not a Spec Drift. Red (known issue goes unrecorded) the moment
    /// the label is made to match.
    @Test("OC-7105 the paused icon's accessibility label reads 'Flotsam, paused'")
    func oc7105_pausedLabelWording() {
        // given the paused icon
        let key = MenuBarModel.icon(mode: .paused, hasWarning: false).accessibilityKeys[0]

        // when its VoiceOver label is read
        // then it is the contract's wording
        withKnownIssue("OC-7105 product defect (Minor): ui.menu.iconPaused is 'Flotsam, capture paused'; contract and DESIGN.md say 'Flotsam, paused'") {
            #expect(FlotsamStrings.text(forKey: key) == "Flotsam, paused")
        }
    }

    /// OC-7108. In every mode the menu has exactly one capture-mode row, it is Pause or Resume Capture, and no number
    /// of presses reaches Curated; Curated is reachable only by writing the setting (Storage), which persists.
    /// Red if a mode gains a second or a Curated row, a toggle's `next` becomes `.curated`, or the title is not Pause/Resume Capture.
    @Test("OC-7108 the menu offers only Pause or Resume Capture in every mode and no press selects Curated")
    func oc7108_menuNeverOffersCurated() {
        let titles = ["Pause Capture", "Resume Capture"]
        for startMode in CaptureMode.allCases {
            // given the menu opened in this mode
            let disk = MemoryKeyValueStore()
            let settings = SettingsStore(store: disk)
            settings.set(startMode, for: SettingKeys.captureMode)
            var mode = startMode

            // when the capture-mode rows are listed, and the row is pressed four times in a row
            for _ in 0..<4 {
                let rows = MenuBarModel.entries(settings: settings)
                let toggles = rows.compactMap { row -> (titleKey: String, next: CaptureMode)? in
                    if case .captureToggle(let key, let next) = row { return (key, next) }
                    return nil
                }

                // then exactly one such row, titled Pause or Resume Capture, that never selects Curated
                #expect(toggles.count == 1, "mode \(mode)")
                let toggle = toggles.first
                #expect(titles.contains(FlotsamStrings.text(forKey: toggle?.titleKey ?? "") ?? ""), "mode \(mode)")
                #expect(toggle?.next != .curated, "mode \(mode)")
                #expect(toggle?.next != mode, "pressing the row changes the mode")
                settings.set(toggle?.next ?? .curated, for: SettingKeys.captureMode)
                mode = settings.value(SettingKeys.captureMode)
                if startMode != .curated { #expect(mode != .curated, "pressing from \(startMode) reached Curated") }
            }
        }
        // and Curated is selectable in Settings: it is one of the three offered modes and round-trips a fresh store
        #expect(CaptureMode.allCases.map { $0.label.text } == ["Active", "Paused", "Curated"])
        let disk = MemoryKeyValueStore()
        SettingsStore(store: disk).set(CaptureMode.curated, for: SettingKeys.captureMode)
        #expect(SettingsStore(store: disk).value(SettingKeys.captureMode) == .curated)
    }
}
