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
}
