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

/// Holds the watcher's `report` hook, so a test can park a rebuild exactly at its suspension and run other calls then.
private final class ReportGate: @unchecked Sendable {
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

@Suite("TASK-457: ScreenshotWatcher rebuild overtaken while suspended", .serialized)
struct Task457WatcherRaceTests {
    /// The rig's watcher cannot gate `report`, so this one is built over the same folders, clock, source and stores.
    private func gatedWatcher(_ rig: WatcherRig, gate: ReportGate) -> ScreenshotWatcher {
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
    private func parkRebuild(_ rig: WatcherRig, _ watcher: ScreenshotWatcher, gate: ReportGate) async throws -> Handoff<Bool> {
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
        let gate = ReportGate()
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
        let gate = ReportGate()
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
}
