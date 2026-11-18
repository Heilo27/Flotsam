import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots
@testable import FlotsamStorage

// TASK-490 (FRD-002 FR-002-05): the off-path leftovers TASK-483 left in `ScreenshotWatcher`. Each test parks the watcher
// at ONE suspension, lets pickup go off (and on) meanwhile, and judges what the user can see: the notices raised and
// cleared. Reproduction tests, written from the ticket's findings before the fixes; each "after off" test was red on
// the code at dad5b36.

/// A watermark store whose loads and writes can be held and made to fail, to park the watcher inside `currentWatermark`
/// and `advanceWatermark` and then fail them.
private final class Task490Store: ScreenshotWatermarkStore, @unchecked Sendable {
    private let inner: MemoryWatermarkStore
    let loadGate = WorfGate()
    let writeGate = WorfGate()
    private let lock = NSLock()
    private var loadFails = false
    private var writeFails = false

    init(_ inner: MemoryWatermarkStore) { self.inner = inner }

    func failLoads() { lock.withLock { loadFails = true } }
    func failWrites() { lock.withLock { writeFails = true } }

    func lastScanAt() async -> FlotsamResult<Date?> {
        await loadGate.pass()
        if lock.withLock({ loadFails }) { return .failure(FlotsamError(.stoDb001, "the watermark could not be read")) }
        return await inner.lastScanAt()
    }

    func setLastScanAt(_ date: Date) async -> FlotsamResult<Void> {
        await writeGate.pass()
        if lock.withLock({ writeFails }) { return .failure(FlotsamError(.stoDb001, "the watermark could not be written")) }
        return await inner.setLastScanAt(date)
    }
}

/// The rig's ingest, but every created item carries `warning` (an import that stored the item and has something to say).
private struct Task490WarningIngest: ScreenshotIngesting {
    let inner: IngestRecorder
    let warning: FlotsamError

    func ingest(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult> {
        switch await inner.ingest(candidate) {
        case .success(let result): .success(IngestResult(outcome: result.outcome, warnings: [warning]))
        case .failure(let error): .failure(error)
        }
    }
}

@Suite("TASK-490: FR-002-05 off-path leftovers", .serialized)
struct Task490OffPathLeftoversTests {
    // MARK: Rig helpers

    /// A watcher over the rig's folders. `clear` takes effect first and then waits at `holdClear`'s gate: the real
    /// `ErrorReporter` applies a clear at the start of the call and only then awaits its presenter, so that is the
    /// suspension another caller can overtake.
    private func makeWatcher(
        _ rig: WatcherRig, ingest: (any ScreenshotIngesting)? = nil, marks: (any ScreenshotWatermarkStore)? = nil,
        holdClear: (code: ErrorCode, gate: WorfGate)? = nil
    ) -> ScreenshotWatcher {
        let notices = rig.notices
        return ScreenshotWatcher(
            fileSystem: rig.fileSystem, preferences: rig.preferences, home: rig.home, clock: rig.clock,
            eventSource: rig.source, settings: rig.settings, ingest: ingest ?? rig.ingest,
            watermarkStore: marks ?? rig.marks,
            report: { notices.raise($0) },
            clear: { code in
                notices.clear(code)
                if let holdClear, holdClear.code == code { await holdClear.gate.pass() }
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

    /// A live screenshot whose import is held in flight at the ingest, with pickup on.
    private func liveImportInFlight(
        _ rig: WatcherRig, _ watcher: ScreenshotWatcher, name: String, failing error: FlotsamError? = nil
    ) async throws {
        await watcher.start()
        if let error { rig.ingest.fail(name, with: error) }
        rig.ingest.holdIngests()
        let url = try rig.shot(in: rig.desktop, name)
        rig.event(url)
        try #require(await eventually { rig.ingest.heldIngests >= 1 }, "the live import is in flight at the ingest")
    }

    /// Lets the held ingest return and waits until the watcher has had time to act on it.
    private func finishIngest(_ rig: WatcherRig) async throws {
        rig.ingest.releaseIngests()
        try #require(await eventually { rig.ingest.candidates.count >= 1 }, "the import ended")
        await letItSettle()
    }

    private let rejection = FlotsamError(.sspVal001, "Not a regular file inside the screenshot folder")
    private let storeFailure = FlotsamError(.stoDb001, "the library could not be written")

    // MARK: F1: finish reports only while its job's session is live (mutation: drop the gate on that report)

    @Test("Task490 F1 a live import rejected after pickup went off reports nothing")
    func rejectedLiveImportAfterOff() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig)
        try await liveImportInFlight(rig, watcher, name: "Screenshot a.png", failing: rejection)

        await setPickup(false, rig, watcher)
        try await finishIngest(rig)

        #expect(rig.notices.raised(.sspVal001) == 0, "FR-002-05: off means no reports left standing for a file nobody watches")
        #expect(await watcher.status == .off)
    }

    @Test("Task490 F1 a live import that failed to store after pickup went off reports nothing")
    func failedLiveImportAfterOff() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig)
        try await liveImportInFlight(rig, watcher, name: "Screenshot a.png", failing: storeFailure)

        await setPickup(false, rig, watcher)
        try await finishIngest(rig)

        #expect(rig.notices.raised(.stoDb001) == 0, "FR-002-05: no failure notice after off")
    }

    @Test("Task490 F1 the warnings of a live import that ended after pickup went off are not reported")
    func warningsOfLiveImportAfterOff() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig, ingest: Task490WarningIngest(inner: rig.ingest, warning: FlotsamError(.sspLim001, "warning")))
        try await liveImportInFlight(rig, watcher, name: "Screenshot a.png")

        await setPickup(false, rig, watcher)
        try await finishIngest(rig)

        #expect(rig.notices.raised(.sspLim001) == 0, "FR-002-05: an ended session's import warnings are nobody's notice")
    }

    @Test("Task490 F1 a live import of the old session rejected after off and on again reports nothing")
    func rejectedLiveImportAcrossOffOn() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig)
        try await liveImportInFlight(rig, watcher, name: "Screenshot a.png", failing: rejection)

        await setPickup(false, rig, watcher)
        await setPickup(true, rig, watcher)
        try await finishIngest(rig)

        #expect(rig.notices.raised(.sspVal001) == 0, "the new session did not inherit the old session's rejection")
    }

    @Test("Task490 F1 control: a live import rejected while pickup is on still reports once")
    func rejectedLiveImportWhileOn() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig)
        try await liveImportInFlight(rig, watcher, name: "Screenshot a.png", failing: rejection)

        try await finishIngest(rig)

        #expect(rig.notices.raised(.sspVal001) == 1)
    }

    @Test("Task490 F1 control: a press's import rejected after pickup went off still reports (the user's own request)")
    func rejectedPressImportAfterOff() async throws {
        // given: pickup on; a press importing an hour-old screenshot, held at the ingest
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let watcher = makeWatcher(rig)
        let name = "Screenshot old.png"
        try rig.shot(in: rig.desktop, name, born: rig.clock.now().addingTimeInterval(-3600))
        await watcher.start()
        rig.ingest.fail(name, with: rejection)
        rig.ingest.holdIngests()
        let press = run { _ = await watcher.importRecent() }
        try #require(await eventually { rig.ingest.heldIngests >= 1 }, "the press's import is in flight at the ingest")

        // when: pickup goes off, then the import ends rejected
        await setPickup(false, rig, watcher)
        try await finishIngest(rig)
        try #require(await eventually { press.value == true }, "the press ended")

        // then: FR-002-12: the press's notice stands
        #expect(rig.notices.raised(.sspVal001) == 1)
    }

    // MARK: F2: the watermark failure reports (mutation: drop the gate in `currentWatermark` / `advanceWatermark`)

    @Test("Task490 F2 a watermark load that fails after pickup went off reports nothing")
    func watermarkLoadFailsAfterOff() async throws {
        // given: a fresh activation parked on its first watermark load
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let store = Task490Store(rig.marks)
        let watcher = makeWatcher(rig, marks: store)
        store.failLoads()
        store.loadGate.close()
        let activation = run { await watcher.settingsDidChange() }
        try #require(await eventually { store.loadGate.waiting >= 1 }, "the activation parked on its watermark load")

        // when: pickup goes off, then the load returns its failure
        await setPickup(false, rig, watcher)
        store.loadGate.open()
        try #require(await eventually { activation.value == true }, "the activation ended")

        // then: FR-002-05: the failure is nobody's notice
        #expect(rig.notices.raised(.stoDb001) == 0)
        #expect(await watcher.status == .off)
    }

    @Test("Task490 F2 control: a watermark load that fails while pickup is on reports")
    func watermarkLoadFailsWhileOn() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let store = Task490Store(rig.marks)
        let watcher = makeWatcher(rig, marks: store)
        store.failLoads()

        await watcher.settingsDidChange()

        #expect(rig.notices.raised(.stoDb001) >= 1)
    }

    @Test("Task490 F2 a watermark write that fails after pickup went off reports nothing")
    func watermarkWriteFailsAfterOff() async throws {
        // given: a fresh activation parked on its watermark write
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let store = Task490Store(rig.marks)
        let watcher = makeWatcher(rig, marks: store)
        store.failWrites()
        store.writeGate.close()
        let activation = run { await watcher.settingsDidChange() }
        try #require(await eventually { store.writeGate.waiting >= 1 }, "the activation parked on its watermark write")

        // when: pickup goes off, then the write returns its failure
        await setPickup(false, rig, watcher)
        store.writeGate.open()
        try #require(await eventually { activation.value == true }, "the activation ended")

        // then
        #expect(rig.notices.raised(.stoDb001) == 0, "FR-002-05: the failure is nobody's notice")
    }

    @Test("Task490 F2 control: a watermark write that fails while pickup is on reports")
    func watermarkWriteFailsWhileOn() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let store = Task490Store(rig.marks)
        let watcher = makeWatcher(rig, marks: store)
        store.failWrites()

        await watcher.settingsDidChange()

        #expect(rig.notices.raised(.stoDb001) >= 1)
    }

    // MARK: F3: the press's refusal and `accessDenied` have one owner (mutation: report without setting the flag)

    @Test("Task490 F3 a refusal found by a press is cleared when pickup goes off")
    func pressRefusalClearedByOff() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)

        let result = await rig.watcher.importRecentWithin()
        try #require(result != nil && (try? result?.get()) == nil, "the press failed with the refusal")
        try #require(rig.notices.standing(.sspPrm001), "control: the press raised SSP-PRM-001")
        await setPickup(false, rig, rig.watcher)

        #expect(!rig.notices.standing(.sspPrm001), "FR-002-05: no condition outlives pickup, whoever found it")
    }

    @Test("Task490 F3 a refusal a press raised while pickup is off is cleared by the next press that can read the folder")
    func pressRefusalClearedByLaterPress() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        _ = await rig.watcher.importRecentWithin()
        try #require(rig.notices.standing(.sspPrm001), "control: the refused press raised SSP-PRM-001")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.desktop.path)
        let result = await rig.watcher.importRecentWithin()

        #expect((try? result?.get()) == 0, "control: the second press reached the folder")
        #expect(!rig.notices.standing(.sspPrm001), "the refusal ended, so its notice must")
    }

    // MARK: F4: deactivate's clear loop does not wipe a notice a later activation raised
    // (mutation: drop the re-check before each clear in `deactivate`)

    @Test("Task490 F4 off then on while off is still clearing: the new activation's notice is not wiped by the stale clear")
    func staleClearDoesNotWipeNewNotice() async throws {
        // given: polling fallback (SSP-OS-001) over a refused folder (SSP-PRM-001); off clears PRM first, then OS
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspPrm001, gate))
        rig.source.setFailing(true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        await watcher.start()
        try #require(rig.notices.standing(.sspOs001), "control: the fallback raised SSP-OS-001")
        try #require(rig.notices.standing(.sspPrm001), "control: the refused folder raised SSP-PRM-001")
        gate.close()
        let off = run { await self.setPickup(false, rig, watcher) }
        try #require(await eventually { gate.waiting >= 1 }, "off parked after clearing SSP-PRM-001, SSP-OS-001 still to clear")

        // when: pickup is turned on again (it raises SSP-OS-001 for its own fallback), then the off finishes its clears
        await setPickup(true, rig, watcher)
        try #require(lastNotice(rig, .sspOs001) == .raised(.sspOs001), "control: the new activation raised SSP-OS-001")
        gate.open()
        try #require(await eventually { off.value == true }, "the off ended")

        // then: the condition holds, so its notice stands: the last word on SSP-OS-001 is a raise
        #expect(lastNotice(rig, .sspOs001) == .raised(.sspOs001), "the stale clear of the old session wiped the new notice")
    }

    // MARK: F5: a rebuild parked in a clear does not win over a later settings change that resolves back
    // (mutation: drop `location = nil` at the top of `rebuild`)

    @Test("Task490 F5 a later settings change that resolves to the old location is not skipped: the parked rebuild loses")
    func laterResolutionToOldLocationBeatsParkedRebuild() async throws {
        // given: the system location is unusable (Desktop under SSP-IO-001); rebuild A, for a chosen folder, parks
        // clearing SSP-IO-001
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        await watcher.start()
        try #require(rig.notices.standing(.sspIo001), "control: the unusable system location raised SSP-IO-001")
        try #require(await watcher.status == .usingDesktop, "control: Desktop is watched")
        let chosen = try rig.temp.folder("Pictures/Chosen")
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        gate.close()
        let rebuildA = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "rebuild A parked clearing SSP-IO-001")

        // when: the override is removed (the setting resolves to Desktop again, the location the watcher still shows),
        // then A resumes
        rig.settings.set(FolderOverride.none, for: SettingKeys.screenshotsFolderOverride)
        await watcher.settingsDidChange()
        gate.open()
        try #require(await eventually { rebuildA.value == true }, "rebuild A ended")

        // then: the settings the user ended with win: Desktop under SSP-IO-001, not the chosen folder A resolved
        #expect(await watcher.status == .usingDesktop, "A installed a resolution the settings no longer ask for")
        #expect(lastNotice(rig, .sspIo001) == .raised(.sspIo001), "Desktop is in use because the system location is unusable")
    }
}
