import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamScreenshots

// FRD-007 8T contract tests, slice S2 (Screenshots half): OC-7102 and the screenshot half of OC-7103. Real
// ScreenshotWatcher over a temporary tree (WatcherRig): fake clock, folder events, ingest and watermark. No pasteboard.
// The clipboard halves are in FlotsamCaptureTests (same file name). The sentence "copies text AND takes a screenshot"
// spans two modules no test target imports together (ADR-0001), so each half asserts its own count; see
// FRD007ContractTestsGaps.swift.

@Suite("FRD-007 contract: capture modes (Screenshots)", .serialized, .timeLimit(.minutes(2)))
struct FRD007ContractCaptureModeScreenshotTests {
    private func earlierLaunch() -> Date { Date().addingTimeInterval(-10) }

    /// OC-7102 (screenshot half). Paused: a screenshot is not imported; after resume it is still not imported (no
    /// backfill), the file is still on disk, and the next screenshot is.
    /// Red if Paused imports, if resume backfills the paused-period shot, or if pausing removes the file.
    @Test("OC-7102 Paused then resumed: the paused-period screenshot is never imported and its file stays on disk")
    func oc7102_pausedShotNeverImportedFileSurvives() async throws {
        // given Paused, the Desktop watched
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        await rig.watcher.start()
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        await rig.watcher.settingsDidChange()

        // when a screenshot is taken, 5 s pass, then the user resumes
        let shot = try rig.shot(in: rig.desktop)
        let bytesBefore = try Data(contentsOf: shot)
        rig.event(shot)
        rig.clock.advance(by: 5)
        await letItSettle()
        #expect(rig.ingest.candidates.isEmpty, "nothing imported while paused")
        rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
        await rig.watcher.settingsDidChange()
        await rig.watcher.didBecomeActive()
        await rig.tick()
        await letItSettle()

        // then still nothing imported, and the file is on disk, unchanged
        #expect(rig.ingest.candidates.isEmpty, "no backfill after resume")
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(try Data(contentsOf: shot) == bytesBefore)

        // control: a screenshot taken after resume IS imported, so the empty list above is the pause
        let later = try rig.shot(in: rig.desktop, born: rig.clock.now().addingTimeInterval(1))
        rig.event(later)
        #expect(await eventually { rig.ingest.names == [later.lastPathComponent] })
        #expect(!rig.ingest.names.contains(shot.lastPathComponent))
    }

    /// OC-7103 (screenshot half). Curated: a screenshot is never imported, and no screenshot item is ever created,
    /// including after the mode is later set back to Active.
    /// Red if Curated imports screenshots, or switching back backfills them.
    @Test("OC-7103 Curated: a screenshot creates no item, now or after the mode returns to Active")
    func oc7103_curatedShotNeverImported() async throws {
        // given Curated, the Desktop watched
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(CaptureMode.curated, for: SettingKeys.captureMode)
        await rig.watcher.start()

        // when a screenshot is taken
        let shot = try rig.shot(in: rig.desktop)
        rig.event(shot)
        await rig.tick()
        await letItSettle()

        // then delta 0; and the same after returning to Active; the file is untouched
        #expect(rig.ingest.candidates.isEmpty)
        rig.clock.advance(by: 60)
        rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
        await rig.watcher.settingsDidChange()
        await rig.watcher.didBecomeActive()
        await rig.tick()
        await letItSettle()
        #expect(rig.ingest.candidates.isEmpty)
        #expect(FileManager.default.fileExists(atPath: shot.path))
    }

    /// FR-007-12 / AC-007-10 (screenshot pickup, the persisted half). Paused and Curated both let the reconcile scan advance
    /// `screenshots.lastScanAt` without importing, so the persisted watermark ends up past a screenshot taken in the
    /// mode (what keeps it from being imported after a relaunch or a resume). Asserted on the persisted watermark
    /// itself, not on a later import. Red if a non-importing scan stops advancing the watermark (the empty-list
    /// checks above are then carried by the mode-change advance alone).
    @Test("FR-007-12 Paused and Curated: a reconcile scan advances lastScanAt past the screenshot and imports nothing",
          arguments: [CaptureMode.paused, CaptureMode.curated])
    func pickupAdvancesWatermarkWithoutImporting(mode: CaptureMode) async throws {
        // given the mode set before launch, the watermark 10 s back, and a screenshot taken now
        let rig = try WatcherRig(watermark: earlierLaunch())
        defer { rig.cleanUp() }
        rig.settings.set(mode, for: SettingKeys.captureMode)
        await rig.watcher.start()
        let shot = try rig.shot(in: rig.desktop)
        let shotTime = rig.clock.now()
        let before = try #require(rig.marks.value)

        // when 60 s pass and the app becomes active (a reconcile scan; not the 30 s tick, which advances the watermark
        // in every mode and would hide a scan that does not)
        rig.clock.advance(by: 60)
        await rig.watcher.didBecomeActive()
        await letItSettle()

        // then the persisted watermark moved past the screenshot, nothing was imported, the file is on disk
        let after = try #require(rig.marks.value)
        #expect(after > before, "\(mode): the watermark did not move")
        #expect(after >= shotTime.addingTimeInterval(59), "\(mode): the watermark did not pass the screenshot")
        #expect(rig.ingest.candidates.isEmpty, "\(mode): nothing is imported")
        #expect(FileManager.default.fileExists(atPath: shot.path))

        // control: Active over the same sequence imports the screenshot, so the empty list above is the mode
        let live = try WatcherRig(watermark: earlierLaunch())
        defer { live.cleanUp() }
        await live.watcher.start()
        let liveShot = try live.shot(in: live.desktop)
        live.event(liveShot)
        #expect(await eventually { live.ingest.names == [liveShot.lastPathComponent] })
    }
}
