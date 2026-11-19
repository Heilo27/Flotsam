import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-510: `ScreenshotWatcher.stop()` ends a watcher for good (quit, or the test rig replacing it on a relaunch). After
// it returns nothing reaches the ingest from that watcher, and what it had already accepted has finished.

@Suite("TASK-510: ScreenshotWatcher.stop", .serialized)
struct Task510WatcherStopTests {
    /// given a watcher that imported one file and is then stopped, when an old watch's event, a rescan, a tick, a wake,
    /// an activation, a settings change, a start and a press all arrive, then nothing more is ingested, no watch is
    /// running and the press fails as paused. Red if `stop()` leaves the watch, the timer or the entry points live.
    @Test("no event, tick, wake, activation, settings change, start or press reaches the ingest after stop")
    func nothingArrivesAfterStop() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let before = try rig.shot(in: rig.desktop, "Screenshot before.png")
        rig.event(before)
        #expect(await eventually { rig.ingest.names == [before.lastPathComponent] }, "control: a live watcher imports")
        let oldWatch = try #require(rig.source.watches.last)

        await rig.watcher.stop()

        let after = try rig.shot(in: rig.desktop, "Screenshot after.png")
        rig.source.emit(.changed([after]), on: oldWatch)
        rig.source.emit(.rescan, on: oldWatch)
        await rig.tick()
        await rig.watcher.didWake()
        await rig.watcher.didBecomeActive()
        await rig.watcher.settingsDidChange()
        await rig.watcher.start()
        let press = await rig.watcher.importRecentWithin()
        await letItSettle()
        #expect(rig.ingest.names == [before.lastPathComponent], "ingested after stop: \(rig.ingest.names)")
        #expect(rig.source.running.isEmpty, "a watch is still running after stop")
        #expect(await rig.watcher.status == .off)
        guard case .failure = press else { Issue.record("a press after stop must fail as paused, got \(String(describing: press))"); return }
    }

    /// given an import held in the ingest, when `stop()` is called, then it does not return until the import has ended and
    /// its watermark write has landed; and the held file's import is not abandoned. Red if `stop()` returns while an
    /// import is still running (a relaunch would then read a watermark the old watcher is still about to move).
    @Test("stop waits for the import in flight and its watermark write")
    func stopDrainsInFlightImport() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let born = rig.clock.now()
        let held = try rig.shot(in: rig.desktop, "Screenshot held.png", born: born)
        rig.ingest.holdIngest(named: held.lastPathComponent)
        rig.event(held)
        #expect(await eventually { rig.ingest.heldIngests == 1 })
        let marked = rig.marks.value
        let returned = Handoff<Bool>()
        let watcher = rig.watcher!
        Task {
            await watcher.stop()
            returned.set(true)
        }
        await letItSettle()
        #expect(returned.value == nil, "stop returned while an import was still running")

        rig.ingest.releaseIngest(named: held.lastPathComponent)
        #expect(await eventually(timeout: .seconds(20)) { returned.value == true }, "stop never returned")
        #expect(rig.ingest.names == [held.lastPathComponent])
        let after = try #require(rig.marks.value)
        #expect(marked == nil || after >= marked!, "the watermark went backwards")
        #expect(after >= born, "the held import's watermark write had not landed when stop returned: \(after) < \(born)")
    }

    /// given a running watcher, when the rig relaunches, then the old watcher is stopped before the new one exists: its
    /// watch is torn down and a late event on it ingests nothing, so two watchers never read one folder. Red if
    /// `WatcherRig.relaunch()` leaves the old watcher running (the 38 relaunch call sites rely on it).
    @Test("relaunch stops the previous watcher: its watch is gone and a late event on it ingests nothing")
    func relaunchStopsPreviousWatcher() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let oldWatch = try #require(rig.source.watches.last)
        let old = try #require(rig.watcher)
        #expect(rig.source.running.count == 1, "control: the watcher is watching")

        await rig.relaunch()

        #expect(rig.source.running.isEmpty, "the old watcher's watch survived the relaunch")
        #expect(await old.status == .off)
        let late = try rig.shot(in: rig.desktop, "Screenshot late.png")
        rig.source.emit(.changed([late]), on: oldWatch)
        await letItSettle()
        #expect(rig.ingest.names.isEmpty, "the old watcher ingested after the relaunch: \(rig.ingest.names)")
    }
}
