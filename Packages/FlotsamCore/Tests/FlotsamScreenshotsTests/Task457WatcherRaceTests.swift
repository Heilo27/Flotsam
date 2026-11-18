import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-457 item 1: actor re-entrancy in `ScreenshotWatcher.rebuild(for:)`.
//
// `rebuild` tears the old watch down, then suspends (raising or clearing the location notice goes through the
// `report` / `clear` hooks, which hop to another actor), and only then installs the new location and starts the new
// watch. While it is suspended the watcher actor serves other calls: pickup turned off (`deactivate`), or a second
// re-resolution (`didBecomeActive`, `didWake`, `settingsDidChange`; the 30 s tick is serialized by TASK-427, these are
// not). The resumed rebuild must notice it was overtaken instead of installing a watch nobody owns.
//
// The same shape in the import path (FR-002-05: pickup off means nothing is picked up, and nothing a pickup left
// behind outlives it): `reconcileScan` and `ingestEvents` suspend on the first watermark load and used to queue
// imports afterwards whether or not pickup had been turned off meanwhile, and an import that was already running when
// pickup went off put its file back on the retry list that `deactivate` had just emptied.

/// Holds a hook the watcher awaits (`report`, the watermark load), so a test can park the watcher exactly at that
/// suspension and run other calls then.
private final class Gate: @unchecked Sendable {
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

/// The rig's watermark store, with the first load held while `gate` is closed (a slow database).
private final class GatedWatermarkStore: ScreenshotWatermarkStore, @unchecked Sendable {
    private let inner: MemoryWatermarkStore
    private let gate: Gate

    init(_ inner: MemoryWatermarkStore, gate: Gate) {
        self.inner = inner
        self.gate = gate
    }

    func lastScanAt() async -> FlotsamResult<Date?> {
        await gate.pass()
        return await inner.lastScanAt()
    }

    func setLastScanAt(_ date: Date) async -> FlotsamResult<Void> { await inner.setLastScanAt(date) }
}

@Suite("TASK-457: ScreenshotWatcher rebuild overtaken while suspended", .serialized)
struct Task457WatcherRaceTests {
    /// The rig's watcher cannot gate `report`, so this one is built over the same folders, clock, source and stores.
    private func gatedWatcher(_ rig: WatcherRig, gate: Gate) -> ScreenshotWatcher {
        let notices = rig.notices
        return ScreenshotWatcher(
            fileSystem: rig.fileSystem, preferences: rig.preferences, home: rig.home, clock: rig.clock,
            eventSource: rig.source, settings: rig.settings, ingest: rig.ingest, watermarkStore: rig.marks,
            report: { error in
                await gate.pass()
                notices.raise(error)
            },
            clear: { notices.clear($0) }, pollTick: rig.pollTick, sink: rig.sink)
    }

    /// A system `location` that does not exist: the next re-resolution is `.usingDesktop`, which raises `SSP-IO-001`
    /// through the gated `report`, so the rebuild parks between its teardown and its new watch.
    private func parkRebuild(_ rig: WatcherRig, _ watcher: ScreenshotWatcher, gate: Gate) async throws -> Handoff<Bool> {
        gate.close()
        rig.preferences.set(location: rig.temp.root.appendingPathComponent("gone-\(UUID().uuidString)").path)
        let done = Handoff<Bool>()
        Task {
            await watcher.didBecomeActive()
            done.set(true)
        }
        try #require(await eventually { gate.waiting >= 1 }, "the rebuild parked in its notice")
        return done
    }

    @Test("pickup turned off while a rebuild is parked: the rebuild must not start a watch or call the folder watched")
    func rebuildOvertakenByDeactivate() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = Gate()
        let watcher = gatedWatcher(rig, gate: gate)
        await watcher.start()
        #expect(rig.source.running.count == 1)

        let rebuild = try await parkRebuild(rig, watcher, gate: gate)
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        await watcher.settingsDidChange()
        gate.open()
        try #require(await eventually { rebuild.value == true }, "the parked rebuild ended")

        #expect(await watcher.status == .off, "FR-002-05: pickup is off, so the status says so")
        #expect(rig.source.running.isEmpty, "FR-002-05: pickup is off, so no folder watch is left running")
    }

    @Test("a second re-resolution overtakes a parked rebuild: exactly one watch is left running")
    func rebuildOvertakenByRebuild() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = Gate()
        let watcher = gatedWatcher(rig, gate: gate)
        await watcher.start()

        let first = try await parkRebuild(rig, watcher, gate: gate)
        // The notice is already raised for this state, so the second rebuild does not park: it runs to the end.
        await watcher.didBecomeActive()
        gate.open()
        try #require(await eventually { first.value == true }, "the parked rebuild ended")

        #expect(rig.source.running.count == 1, "the overtaken rebuild must not leave a second, unowned watch running")
        #expect(await watcher.status == .usingDesktop)
    }

    // MARK: Import path

    /// A watcher over the rig whose watermark load is held while `gate` is closed. `start()` keeps the stored
    /// watermark, so its first scan loads it: that load is the suspension these tests park the watcher at.
    private func slowWatermarkWatcher(_ rig: WatcherRig, gate: Gate) -> ScreenshotWatcher {
        let notices = rig.notices
        return ScreenshotWatcher(
            fileSystem: rig.fileSystem, preferences: rig.preferences, home: rig.home, clock: rig.clock,
            eventSource: rig.source, settings: rig.settings, ingest: rig.ingest,
            watermarkStore: GatedWatermarkStore(rig.marks, gate: gate),
            report: { notices.raise($0) }, clear: { notices.clear($0) }, pollTick: rig.pollTick, sink: rig.sink)
    }

    private func turnPickupOff(_ rig: WatcherRig, _ watcher: ScreenshotWatcher) async {
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        await watcher.settingsDidChange()
    }

    /// Lets whatever import the watcher queued run to its end: a queued job waits 0.5 s for the file to settle.
    private func runQueuedImports(_ rig: WatcherRig) async {
        await letItSettle()
        rig.clock.advance(by: 1)
        await letItSettle()
    }

    @Test("pickup turned off while the reconcile scan waits for the watermark: the scan queues nothing")
    func reconcileScanOvertakenByDeactivate() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = Gate()
        let watcher = slowWatermarkWatcher(rig, gate: gate)
        try rig.shot(in: rig.desktop)  // listed by the scan before it parks, newer than the watermark: it would queue it

        gate.close()
        let started = Handoff<Bool>()
        Task {
            await watcher.start()
            started.set(true)
        }
        try #require(await eventually { gate.waiting >= 1 }, "the first scan parked on the watermark load")
        await turnPickupOff(rig, watcher)
        gate.open()
        try #require(await eventually { started.value == true }, "the parked start ended")
        await runQueuedImports(rig)

        #expect(rig.ingest.names.isEmpty, "FR-002-05: pickup is off, so a scan that was overtaken imports nothing")
    }

    @Test("pickup turned off while a file event waits for the watermark: the event queues nothing")
    func ingestEventsOvertakenByDeactivate() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = Gate()
        let watcher = slowWatermarkWatcher(rig, gate: gate)

        gate.close()
        let started = Handoff<Bool>()
        Task {
            await watcher.start()
            started.set(true)
        }
        try #require(await eventually { gate.waiting >= 1 }, "the first scan parked on the watermark load")
        // Born after that scan listed the folder, so only the event can queue it.
        let url = try rig.shot(in: rig.desktop)
        rig.event(url)
        try #require(await eventually { gate.waiting >= 2 }, "the event parked on the watermark load too")
        await turnPickupOff(rig, watcher)
        gate.open()
        try #require(await eventually { started.value == true }, "the parked start ended")
        await runQueuedImports(rig)

        #expect(rig.ingest.names.isEmpty, "FR-002-05: pickup is off, so an event that was overtaken imports nothing")
    }

    @Test("an import that goes unstable after pickup was turned off leaves no retry that a later reactivation imports")
    func unstableImportEndingAfterDeactivate() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let files = HeldReadFileSystem(rig.fileSystem)
        let watcher = ScreenshotWatcher(
            fileSystem: files, preferences: rig.preferences, home: rig.home, clock: rig.clock, eventSource: rig.source,
            settings: rig.settings, ingest: rig.ingest, watermarkStore: rig.marks,
            report: { [notices = rig.notices] in notices.raise($0) }, clear: { [notices = rig.notices] in notices.clear($0) },
            pollTick: rig.pollTick, sink: rig.sink)
        await watcher.start()
        let url = try rig.shot(in: rig.desktop)
        files.holdReads()
        rig.event(url)
        try #require(await eventually { files.blockedReads >= 1 }, "the import is in flight, about to read the file")

        // The file turns unreadable while that read is pending, and pickup goes off before the read fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        await turnPickupOff(rig, watcher)
        files.releaseReads()
        await letItSettle()  // the import ends `unstable`, after `deactivate` emptied the retry list

        // The file is readable again and older than the reactivation: nothing may pick it up as a retry.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        rig.clock.advance(by: 600)
        rig.settings.set(true, for: SettingKeys.screenshotsEnabled)
        await watcher.settingsDidChange()
        rig.clock.advance(by: ScreenshotWatcher.tickInterval)
        await watcher.tickFired()
        await runQueuedImports(rig)

        #expect(rig.ingest.names.isEmpty, "FR-002-05: nothing from before the off period is imported after it")
    }
}

/// The rig's file system, except that `readFileNoFollow` (the import's single read of the bytes, after the stability
/// check) blocks its caller while reads are held: an import can be in flight when the test turns pickup off.
private final class HeldReadFileSystem: FileSystemPort, @unchecked Sendable {
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
