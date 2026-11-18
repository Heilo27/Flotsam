import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// WORF-457 (FRD-002 FR-002-05): adversarial tests for TASK-457's suspension guards in `ScreenshotWatcher`.
//
// Each test parks the watcher at ONE named suspension (a gated hook), turns pickup off while it waits, releases it,
// and then judges what the user can see: the ingest log, the status, the running watches, the persisted watermark,
// the notices, the registered timer. Each is written against exactly one guard so a mutant that drops that guard turns
// that test red (mutation map in the comment above each test).

/// Holds a hook the watcher awaits, so a test parks the watcher at exactly that suspension.
final class WorfGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var parked = 0

    func close() { lock.withLock { closed = true } }
    func open() { lock.withLock { closed = false } }
    var waiting: Int { lock.withLock { parked } }

    func pass() async {
        guard lock.withLock({ closed }) else { return }
        lock.withLock { parked += 1 }
        while lock.withLock({ closed }) { try? await Task.sleep(for: .milliseconds(5)) }
        lock.withLock { parked -= 1 }
    }
}

/// The rig's watermark store with its loads held while `gate` is closed (a slow database).
private final class WorfSlowLoadStore: ScreenshotWatermarkStore, @unchecked Sendable {
    private let inner: MemoryWatermarkStore
    private let gate: WorfGate
    init(_ inner: MemoryWatermarkStore, gate: WorfGate) { self.inner = inner; self.gate = gate }
    func lastScanAt() async -> FlotsamResult<Date?> {
        await gate.pass()
        return await inner.lastScanAt()
    }
    func setLastScanAt(_ date: Date) async -> FlotsamResult<Void> { await inner.setLastScanAt(date) }
}

/// The rig's file system, except that the import's single read of the bytes blocks while reads are held.
final class WorfHeldReadFileSystem: FileSystemPort, @unchecked Sendable {
    private let base: ProbedFileSystem
    private let lock = NSLock()
    private var held = false
    private var blocked = 0
    init(_ base: ProbedFileSystem) { self.base = base }
    func holdReads() { lock.withLock { held = true } }
    func releaseReads() { lock.withLock { held = false } }
    var blockedReads: Int { lock.withLock { blocked } }

    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> {
        if lock.withLock({ held }) {
            lock.withLock { blocked += 1 }
            while lock.withLock({ held }) { Thread.sleep(forTimeInterval: 0.005) }
            lock.withLock { blocked -= 1 }
        }
        return base.readFileNoFollow(at: url)
    }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { base.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { base.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { base.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { base.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { base.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { base.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { base.writeFile(data, to: url, permissions: permissions) }
    func readFile(at url: URL) -> FlotsamResult<Data> { base.readFile(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { base.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { base.availableCapacity(at: url) }
}

/// A folder event source that is unavailable (the watcher falls back to polling) and runs `action` on its first
/// `start`, then keeps the actor busy for a moment. The action's calls into the watcher queue behind that busy
/// stretch, so they are already waiting for the actor when the stretch ends, ahead of anything the watcher itself
/// queues from it afterwards.
private final class WorfBusyUnavailableSource: FolderEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    func onFirstStart(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }

    func start(watching folder: URL, handler: @escaping @Sendable (FolderEvent) -> Void) -> FlotsamResult<any FolderWatch> {
        if let action = lock.withLock({ () -> (@Sendable () -> Void)? in defer { self.action = nil }; return self.action }) {
            action()
            Thread.sleep(forTimeInterval: 0.2)
        }
        return .failure(FlotsamError(.sspOs001, "Fake source unavailable"))
    }
}

@Suite("WORF-457: FR-002-05 suspension guards in ScreenshotWatcher", .serialized)
struct Worf457WatcherAdversarialTests {
    // MARK: Rig helpers

    /// The rig's watcher with optional seams: a replaced file system, a replaced watermark store, and one notice
    /// code whose `clear` hook is held while its gate is closed.
    private func makeWatcher(
        _ rig: WatcherRig, files: (any FileSystemPort)? = nil, store: (any ScreenshotWatermarkStore)? = nil,
        holdClear: (code: ErrorCode, gate: WorfGate)? = nil, eventSource: (any FolderEventSource)? = nil
    ) -> ScreenshotWatcher {
        let notices = rig.notices
        return ScreenshotWatcher(
            fileSystem: files ?? rig.fileSystem, preferences: rig.preferences, home: rig.home, clock: rig.clock,
            eventSource: eventSource ?? rig.source, settings: rig.settings, ingest: rig.ingest, watermarkStore: store ?? rig.marks,
            report: { notices.raise($0) },
            clear: { code in
                if let holdClear, holdClear.code == code { await holdClear.gate.pass() }
                notices.clear(code)
            },
            pollTick: rig.pollTick, sink: rig.sink)
    }

    private func turnPickupOff(_ rig: WatcherRig, _ watcher: ScreenshotWatcher) async {
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        await watcher.settingsDidChange()
    }

    private func turnPickupOn(_ rig: WatcherRig, _ watcher: ScreenshotWatcher) async {
        rig.settings.set(true, for: SettingKeys.screenshotsEnabled)
        await watcher.settingsDidChange()
    }

    /// Lets queued imports run to their end: a queued job waits 0.5 s on the stepped clock for the file to settle.
    private func runQueuedImports(_ rig: WatcherRig) async {
        await letItSettle()
        rig.clock.advance(by: 1)
        await letItSettle()
    }

    private func run(_ work: @escaping @Sendable () async -> Void) -> Handoff<Bool> {
        let done = Handoff<Bool>()
        Task {
            await work()
            done.set(true)
        }
        return done
    }

    /// The last thing the log says about `code`: raised (standing) or cleared; nil if never mentioned.
    private func lastNotice(_ rig: WatcherRig, _ code: ErrorCode) -> NoticeLog.Entry? {
        rig.notices.entries.last { $0 == .raised(code) || $0 == .cleared(code) }
    }

    /// After pickup was turned off and on again, a screenshot taken in the new session must still arrive by event:
    /// proves the guards stop only the overtaken work, never the session that follows.
    private func importsANewSessionShot(_ rig: WatcherRig, _ watcher: ScreenshotWatcher) async throws -> String {
        rig.clock.advance(by: 600)
        await turnPickupOn(rig, watcher)
        rig.clock.advance(by: 1)
        let survivor = try rig.shot(in: rig.desktop)
        rig.event(survivor)
        await runQueuedImports(rig)
        return survivor.lastPathComponent
    }

    // MARK: reconcileScan: the watermark load (mutation: drop `guard active, generation == current` after `last`)

    @Test("OC-W457-1 reconcileScan parked on the watermark load, pickup off: queues nothing; the next session still imports")
    func scanParkedOnWatermarkLoad() async throws {
        // given: a scan that listed a file newer than the watermark and parks on the watermark load
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, store: WorfSlowLoadStore(rig.marks, gate: gate))
        try rig.shot(in: rig.desktop)
        gate.close()
        let started = run { await watcher.start() }
        try #require(await eventually { gate.waiting >= 1 }, "the first scan parked on the watermark load")

        // when: pickup is turned off, then the scan resumes
        await turnPickupOff(rig, watcher)
        gate.open()
        try #require(await eventually { started.value == true }, "the parked start ended")
        await runQueuedImports(rig)

        // then: the pre-off file was not imported, and a screenshot of the next session still is (exactly one)
        #expect(rig.ingest.names.isEmpty, "FR-002-05: an overtaken scan imports nothing")
        let survivor = try await importsANewSessionShot(rig, watcher)
        #expect(rig.ingest.names == [survivor], "one import, the new session's file")
    }

    // MARK: ingestEvents: the watermark load (mutation: drop the new guard after `known`)

    @Test("OC-W457-2 two file events parked on the watermark load, pickup off: neither queues; the next session still imports")
    func eventsParkedOnWatermarkLoad() async throws {
        // given: a first scan and two events, all parked on the watermark load; the files were born after the scan
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, store: WorfSlowLoadStore(rig.marks, gate: gate))
        gate.close()
        let started = run { await watcher.start() }
        try #require(await eventually { gate.waiting >= 1 }, "the first scan parked")
        rig.event(try rig.shot(in: rig.desktop))
        rig.event(try rig.shot(in: rig.desktop))
        try #require(await eventually { gate.waiting >= 3 }, "both events parked on the watermark load too")

        // when: pickup goes off and everything resumes
        await turnPickupOff(rig, watcher)
        gate.open()
        try #require(await eventually { started.value == true }, "the parked start ended")
        await runQueuedImports(rig)

        // then: neither event imported anything
        #expect(rig.ingest.names.isEmpty, "FR-002-05: events overtaken by pickup-off import nothing")
        let survivor = try await importsANewSessionShot(rig, watcher)
        #expect(rig.ingest.names == [survivor], "one import, the new session's file")
    }

    // MARK: reconcileScan: markAccessGranted (mutation: drop the guard after `markAccessGranted()`)

    @Test("OC-W457-3 scan parked clearing SSP-PRM-001 while capture is Paused, pickup off: the watermark does not move")
    func scanParkedOnAccessGrantedLeavesWatermark() async throws {
        // given: Paused capture (a scan only advances the watermark), a folder that was refused and is readable now
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspPrm001, gate))
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        await watcher.start()
        try #require(await watcher.status == .needsAccess, "the folder is refused")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.desktop.path)
        rig.clock.advance(by: 3600)
        gate.close()
        let scan = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "the scan parked clearing SSP-PRM-001")
        let before = try #require(rig.marks.value)

        // when: pickup is turned off, then the scan resumes
        await turnPickupOff(rig, watcher)
        gate.open()
        try #require(await eventually { scan.value == true }, "the parked scan ended")

        // then: the watermark is exactly where it was, and pickup reads off with no watch
        #expect(rig.marks.value == before, "FR-002-05: an overtaken scan leaves the watermark to its overtaker")
        #expect(await watcher.status == .off)
        #expect(rig.source.running.isEmpty)
    }

    // MARK: rebuild: after updateLocationWarning (mutation: drop `guard active, generation == mine` there)

    @Test("OC-W457-4 rebuild parked in a location notice, pickup off: no watch starts and the status stays off")
    func rebuildParkedInNoticeDoesNotInstallWatch() async throws {
        // given: Desktop watched under SSP-IO-001, then the system location becomes valid: the rebuild parks clearing IO-001
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        await watcher.start()
        try #require(await watcher.status == .usingDesktop)
        let shots = try rig.temp.folder("Pictures/Shots")
        rig.preferences.set(location: shots.path)
        gate.close()
        let rebuild = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "the rebuild parked clearing SSP-IO-001")

        // when: pickup is turned off, then the rebuild resumes
        await turnPickupOff(rig, watcher)
        gate.open()
        try #require(await eventually { rebuild.value == true }, "the parked rebuild ended")

        // then: nothing is watched and the status says off
        #expect(await watcher.status == .off)
        #expect(rig.source.running.isEmpty, "FR-002-05: no folder watch after pickup is off")
    }

    // MARK: rebuild: paused branch after markAccessGranted (mutation: drop the guard before `status = .paused`)

    @Test("OC-W457-5 rebuild to a paused folder parked clearing SSP-PRM-001, pickup off: the status stays off, not paused")
    func pausedRebuildParkedOnAccessGranted() async throws {
        // given: a refused Desktop (SSP-PRM-001 standing), then an unusable override: the rebuild parks clearing PRM-001
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspPrm001, gate))
        let chosen = try rig.temp.folder("Pictures/Chosen")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        await watcher.start()
        try #require(await watcher.status == .needsAccess)
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.hide(chosen)
        gate.close()
        let rebuild = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "the rebuild parked clearing SSP-PRM-001")

        // when: pickup is turned off, then the rebuild resumes
        await turnPickupOff(rig, watcher)
        gate.open()
        try #require(await eventually { rebuild.value == true }, "the parked rebuild ended")

        // then: pickup reads off, not paused
        #expect(await watcher.status == .off, "FR-002-05: an overtaken rebuild must not set a status")
    }

    // MARK: rebuild overtaken by a second rebuild (mutation: drop `generation == mine` from the guards)

    @Test("OC-W457-6 a rebuild overtaken by a newer one installs nothing: exactly one watch, and it is the newer folder's")
    func rebuildOvertakenByNewerRebuild() async throws {
        // given: Desktop watched under SSP-IO-001; a rebuild to Shots parks clearing IO-001
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        await watcher.start()
        let shots = try rig.temp.folder("Pictures/Shots")
        let other = try rig.temp.folder("Pictures/Other")
        rig.preferences.set(location: shots.path)
        gate.close()
        let first = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "the first rebuild parked")

        // when: the location changes again and a newer rebuild runs to its end, then the first resumes
        rig.preferences.set(location: other.path)
        await watcher.didBecomeActive()
        gate.open()
        try #require(await eventually { first.value == true }, "the parked rebuild ended")

        // then: one running watch, on the newer folder
        let running = rig.source.running
        #expect(running.count == 1, "the overtaken rebuild must not leave a second watch")
        #expect(running.first?.folder.lastPathComponent == "Other")
        #expect(await watcher.status == .watching)
    }

    // MARK: finish(.unstable): the session check (mutation: drop `job.session == session`)

    private func unstableRig() throws -> (rig: WatcherRig, files: WorfHeldReadFileSystem, watcher: ScreenshotWatcher) {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        let files = WorfHeldReadFileSystem(rig.fileSystem)
        return (rig, files, makeWatcher(rig, files: files))
    }

    /// Starts an import, holds it at the read, and makes the file unreadable so it ends `unstable` once released.
    private func startUnstableImport(
        _ rig: WatcherRig, _ files: WorfHeldReadFileSystem, _ watcher: ScreenshotWatcher
    ) async throws -> URL {
        await watcher.start()
        let url = try rig.shot(in: rig.desktop)
        files.holdReads()
        rig.event(url)
        try #require(await eventually { files.blockedReads >= 1 }, "the import is in flight at its read")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        return url
    }

    @Test("OC-W457-7 an import in flight when pickup goes off and ending unstable is not retried by the next session")
    func unstableAfterOffIsNotRetried() async throws {
        // given: an import in flight at its read; the file then turns unreadable
        let (rig, files, watcher) = try unstableRig()
        defer { rig.cleanUp() }
        let url = try await startUnstableImport(rig, files, watcher)

        // when: pickup goes off, the import ends unstable, pickup comes back, and ticks and scans run
        await turnPickupOff(rig, watcher)
        files.releaseReads()
        await letItSettle()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        rig.clock.advance(by: 600)
        await turnPickupOn(rig, watcher)
        rig.clock.advance(by: ScreenshotWatcher.tickInterval)
        await watcher.tickFired()
        await watcher.didBecomeActive()
        await runQueuedImports(rig)

        // then: the pre-off file is never imported
        #expect(rig.ingest.names.isEmpty, "FR-002-05: a retry from before the off period must not survive it")
    }

    @Test("OC-W457-8 control: an import ending unstable in the same session is retried by the tick and imported once")
    func unstableInSameSessionIsRetried() async throws {
        // given: an import in flight at its read; the file turns unreadable; pickup stays on
        let (rig, files, watcher) = try unstableRig()
        defer { rig.cleanUp() }
        let url = try await startUnstableImport(rig, files, watcher)

        // when: the import ends unstable, the file becomes readable, and a tick runs
        files.releaseReads()
        await letItSettle()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        await rig.clock.advance(by: ScreenshotWatcher.tickInterval)
        await watcher.tickFired()
        await runQueuedImports(rig)

        // then: the retry imported it exactly once
        #expect(rig.ingest.names == [url.lastPathComponent], "FR-002-07: the retry list still works inside a session")
        #expect(rig.notices.raised(.sspIo002) == 1, "the unstable attempt was reported once")
    }

    // MARK: Gaps: suspensions TASK-457 did not guard (pre-existing races of the same family, fixed in TASK-483).

    @Test("OC-W457-G1 activation parked on its watermark write, pickup off again: no poll timer is left registered")
    func activationOvertakenByDeactivateLeavesNoTimer() async throws {
        // given: the poll needs no fast tick, so the watcher's 30 s registration is the only thing that can set a cadence
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        rig.pollTick.setFastTickNeeded(false)
        rig.marks.holdWrites()
        let activated = run { await rig.watcher.settingsDidChange() }
        try #require(await eventually { rig.marks.heldWrites >= 1 }, "activation parked writing the fresh watermark")
        #expect(rig.pollTick.cadence == nil, "control: nothing is registered while activation is parked")

        // when: pickup is turned off before activation finishes
        await turnPickupOff(rig, rig.watcher)
        rig.marks.releaseWrites()
        try #require(await eventually { activated.value == true }, "activation ended")

        // then: FR-002-05 says no timer
        #expect(rig.pollTick.cadence == nil, "FR-002-05: off means no timer")
        #expect(await rig.watcher.status == .off)
    }

    @Test("OC-W457-G2 scan refused while the watermark is seeded, pickup off meanwhile: SSP-PRM-001 is not left raised")
    func accessDeniedNoticeAfterDeactivate() async throws {
        // given: a library with no watermark yet and a refused Desktop: the refusal parks seeding the watermark
        let rig = try WatcherRig(watermark: nil)
        defer { rig.cleanUp() }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        rig.marks.holdWrites()
        let started = run { await rig.watcher.start() }
        try #require(await eventually { rig.marks.heldWrites >= 1 }, "the refused scan parked seeding the watermark")

        // when: pickup is turned off, then the scan resumes
        await turnPickupOff(rig, rig.watcher)
        rig.marks.releaseWrites()
        try #require(await eventually { started.value == true }, "the parked start ended")

        // then: pickup is off and no refusal notice is left standing for a folder nobody is reading
        #expect(await rig.watcher.status == .off)
        #expect(lastNotice(rig, .sspPrm001) != .raised(.sspPrm001), "FR-002-05: no condition outlives pickup")
    }

    @Test("OC-W457-G3 rebuild parked clearing the old notice, pickup off: SSP-IO-003 is not raised after the off-time clear")
    func locationNoticeRaisedAfterDeactivate() async throws {
        // given: Desktop under SSP-IO-001; an unusable override makes the rebuild raise IO-003 after clearing IO-001
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = makeWatcher(rig, holdClear: (.sspIo001, gate))
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone").path)
        await watcher.start()
        let chosen = try rig.temp.folder("Pictures/Chosen")
        rig.settings.set(try FolderOverride.choosing(chosen).get(), for: SettingKeys.screenshotsFolderOverride)
        rig.fileSystem.hide(chosen)
        gate.close()
        let rebuild = run { await watcher.didBecomeActive() }
        try #require(await eventually { gate.waiting >= 1 }, "the rebuild parked clearing SSP-IO-001")

        // when: pickup is turned off (which clears IO-003), then the rebuild resumes
        await turnPickupOff(rig, watcher)
        gate.open()
        try #require(await eventually { rebuild.value == true }, "the parked rebuild ended")

        // then: SSP-IO-003 does not stand after pickup is off
        #expect(await watcher.status == .off)
        #expect(lastNotice(rig, .sspIo003) != .raised(.sspIo003), "FR-002-05: no condition outlives pickup")
    }

    // MARK: TASK-483 (D4): the polling notice, and SSP-IO-002 after off

    @Test("OC-W483-D4 pickup turned off while the watcher falls back to polling: SSP-OS-001 is not left raised")
    func pollingNoticeRaisedAfterDeactivate() async throws {
        // given: an event source that is unavailable, and an off request that is already waiting for the actor when
        // the watcher installs its polling fallback
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let source = WorfBusyUnavailableSource()
        let watcher = makeWatcher(rig, eventSource: source)
        let off = Handoff<Bool>()
        source.onFirstStart {
            Task {
                rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
                await watcher.settingsDidChange()
                off.set(true)
            }
        }

        // when: pickup starts, falls back to polling, and is turned off straight away
        await watcher.start()
        try #require(await eventually { off.value == true }, "the off request ran")
        await letItSettle()

        // then: pickup is off and the polling notice is not the last word
        #expect(await watcher.status == .off)
        #expect(lastNotice(rig, .sspOs001) != .raised(.sspOs001), "FR-002-05: no condition outlives pickup")
    }

    @Test("OC-W483-IO002 an import in flight when pickup goes off and ending unstable reports no SSP-IO-002")
    func unstableAfterOffReportsNothing() async throws {
        // given: an import in flight at its read; the file then turns unreadable
        let (rig, files, watcher) = try unstableRig()
        defer { rig.cleanUp() }
        _ = try await startUnstableImport(rig, files, watcher)

        // when: pickup goes off and the import ends unstable
        await turnPickupOff(rig, watcher)
        files.releaseReads()
        await letItSettle()

        // then: no notice about a file nobody is watching
        #expect(rig.notices.raised(.sspIo002) == 0, "FR-002-05: a live import of an ended session raises nothing")
    }
}
