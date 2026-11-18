import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// WORF-483 (FRD-002 FR-002-05): adversarial tests for TASK-483's suspension guards in `ScreenshotWatcher`
// (activate's timer, updateLocationWarning, the awaited polling notice, finish(.unstable)).
//
// Each test parks the watcher at ONE named suspension, lets a second caller overtake it, releases it, and judges what
// the user can see (timers, notices, status, the import log). Mutation map in the comment above each test.

@Suite("WORF-483: FR-002-05 suspension guards (second pass)", .serialized)
struct Worf483AdversarialTests {
    // MARK: Rig helpers

    private func makeWatcher(
        _ rig: WatcherRig, files: (any FileSystemPort)? = nil, holdClear: (code: ErrorCode, gate: WorfGate)? = nil
    ) -> ScreenshotWatcher {
        let notices = rig.notices
        return ScreenshotWatcher(
            fileSystem: files ?? rig.fileSystem, preferences: rig.preferences, home: rig.home, clock: rig.clock,
            eventSource: rig.source, settings: rig.settings, ingest: rig.ingest, watermarkStore: rig.marks,
            report: { notices.raise($0) },
            clear: { code in
                if let holdClear, holdClear.code == code { await holdClear.gate.pass() }
                notices.clear(code)
            },
            pollTick: rig.pollTick, sink: rig.sink)
    }

    private func setPickup(_ on: Bool, _ rig: WatcherRig, _ watcher: ScreenshotWatcher) async {
        rig.settings.set(on, for: SettingKeys.screenshotsEnabled)
        await watcher.settingsDidChange()
    }

    private func run(_ work: @escaping @Sendable () async -> Void) -> Handoff<Bool> {
        let done = Handoff<Bool>()
        Task {
            await work()
            done.set(true)
        }
        return done
    }

    private func lastNotice(_ rig: WatcherRig, _ code: ErrorCode) -> NoticeLog.Entry? {
        rig.notices.entries.last { $0 == .raised(code) || $0 == .cleared(code) }
    }

    // MARK: activate: `session == mine` (mutation: change `guard active, session == mine` to `guard active`)

    @Test("OC-W483-1 activation parked on its watermark write, pickup off then on: exactly one timer, and off removes it")
    func offThenOnDuringActivationLeavesOneTimer() async throws {
        // given: the poll needs no fast tick, so the 30 s registration is the only thing that sets a cadence
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        rig.pollTick.setFastTickNeeded(false)
        rig.marks.holdWrites()
        let first = run { await rig.watcher.settingsDidChange() }
        try #require(await eventually { rig.marks.heldWrites >= 1 }, "the first activation parked on its watermark write")
        #expect(rig.pollTick.cadence == nil, "control: nothing registered while it is parked")

        // when: pickup is turned off and on again (the second activation registers its own timer), then the first resumes
        await setPickup(false, rig, rig.watcher)
        await setPickup(true, rig, rig.watcher)
        #expect(rig.pollTick.cadence == 30, "control: the second activation registered exactly its timer")
        rig.marks.releaseWrites()
        try #require(await eventually { first.value == true }, "the first activation ended")

        // then: the overtaken activation added no second timer: turning pickup off leaves none standing
        await setPickup(false, rig, rig.watcher)
        #expect(rig.pollTick.cadence == nil, "FR-002-05: off means no timer, even after an overtaken activation")
        #expect(await rig.watcher.status == .off)
    }

    // MARK: updateLocationWarning: `raisedLocationWarning == wanted`
    // (mutation: drop `, raisedLocationWarning == wanted` from the guard)

    @Test("OC-W483-2 rebuild parked clearing the old notice, a later rebuild owns the notices: the first raises nothing")
    func overtakenRebuildDoesNotRaiseStaleNotice() async throws {
        // given: Desktop under SSP-IO-001; an unusable override makes rebuild A raise SSP-IO-003 after clearing IO-001
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        await watcher.start()
        try #require(rig.notices.raised(.sspIo001) == 1, "control: the unusable system location raised SSP-IO-001")
        let chosen = try rig.temp.folder("Pictures/Chosen")
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.hide(chosen)
        gate.close()
        let rebuildA = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "rebuild A parked clearing SSP-IO-001")

        // when: the override is removed and the system location is fixed (rebuild B finds Desktop normal, owns the
        // notices and clears IO-003), then A resumes
        rig.settings.set(FolderOverride.none, for: SettingKeys.screenshotsFolderOverride)
        rig.preferences.set(location: nil)
        await watcher.settingsDidChange()
        gate.open()
        try #require(await eventually { rebuildA.value == true }, "rebuild A ended")

        // then: SSP-IO-003 is not standing for an override that is gone, and the status is B's
        #expect(lastNotice(rig, .sspIo003) != .raised(.sspIo003), "a notice for a state that no longer holds must not stand")
        #expect(await watcher.status == .watching)
    }

    // MARK: rebuild, folder-less branch: the guard after `leaveFallbackState`/`markAccessGranted`
    // (mutation: drop `guard active, generation == mine` before `status = .paused`)

    @Test("OC-W483-3 rebuild to an unusable folder parked clearing SSP-OS-001, pickup off: status stays off, nothing standing")
    func leavingFallbackParkedThenOff() async throws {
        // given: pickup polling under SSP-OS-001, then an override that makes the folder unusable
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspOs001, gate))
        rig.source.setFailing(true)
        await watcher.start()
        try #require(rig.notices.standing(.sspOs001), "control: the fallback raised SSP-OS-001")
        let chosen = try rig.temp.folder("Pictures/Chosen")
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.hide(chosen)
        gate.close()
        let rebuild = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "the rebuild parked clearing SSP-OS-001 (leaving the fallback)")

        // when: pickup is turned off, then the clear returns
        await setPickup(false, rig, watcher)
        gate.open()
        try #require(await eventually { rebuild.value == true }, "the parked rebuild ended")

        // then: off stays off, and neither notice is left standing
        #expect(await watcher.status == .off, "an overtaken rebuild must not set .paused after off")
        #expect(!rig.notices.standing(.sspOs001))
        #expect(!rig.notices.standing(.sspIo003))
    }

    // MARK: finish(.unstable): the press exemption (mutation: drop `job.batch != nil ||`)

    @Test("OC-W483-4 a press's import ending unstable after pickup went off still reports SSP-IO-002 (the user's own request)")
    func pressUnstableAfterOffStillReports() async throws {
        // given: pickup on; a press (importRecent) importing an hour-old screenshot, held at its read
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let files = WorfHeldReadFileSystem(rig.fileSystem)
        let watcher = makeWatcher(rig, files: files)
        let url = try rig.shot(in: rig.desktop, born: rig.clock.now().addingTimeInterval(-3600))
        await watcher.start()
        files.holdReads()
        let counted = Handoff<Int>()
        let press = run { if case .success(let n) = await watcher.importRecent() { counted.set(n) } }
        try #require(await eventually { files.blockedReads >= 1 }, "the press's import is in flight at its read")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        // when: pickup goes off and the import then ends unstable
        await setPickup(false, rig, watcher)
        files.releaseReads()
        try #require(await eventually { press.value == true }, "the press ended")

        // then: the press's notice stands exactly once, and the press counted nothing
        #expect(rig.notices.raised(.sspIo002) == 1, "FR-002-12: a press's failure notice does not depend on live pickup")
        #expect(counted.value == 0)
        #expect(rig.ingest.names.isEmpty)
    }

    @Test("OC-W483-5 control: a live import of the old session ending unstable after off, then on again, reports nothing")
    func liveUnstableAcrossOffOnReportsNothing() async throws {
        // given: a live import in flight at its read; the file turns unreadable
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let files = WorfHeldReadFileSystem(rig.fileSystem)
        let watcher = makeWatcher(rig, files: files)
        await watcher.start()
        let url = try rig.shot(in: rig.desktop)
        files.holdReads()
        rig.event(url)
        try #require(await eventually { files.blockedReads >= 1 }, "the live import is in flight at its read")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        // when: pickup goes off and straight back on (a new session), then the old import ends unstable
        await setPickup(false, rig, watcher)
        await setPickup(true, rig, watcher)
        files.releaseReads()
        await letItSettle()

        // then: the new session did not inherit the old session's notice
        #expect(rig.notices.raised(.sspIo002) == 0, "the old session's unstable import is nobody's notice")
        #expect(await watcher.status == .watching)
    }
}
