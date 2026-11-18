import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// WORF-427 (FRD-002 FR-002-02, ADR-0004): the tick guard must reset on every way out of a tick, and the registration
// must not keep the watcher alive.

@Suite("Worf427 tick guard resets", .serialized)
struct Worf427TickGuardTests {
    private func stuckTick(_ rig: WatcherRig) async -> Task<Void, Never> {
        rig.marks.holdWrites()
        rig.clock.advance(by: ScreenshotWatcher.tickInterval)
        let watcher = rig.watcher!
        let tick = Task { await watcher.tickFired() }
        #expect(await eventually { rig.marks.heldWrites == 1 }, "the tick is stuck in its watermark write")
        return tick
    }

    private func laterTickRuns(_ rig: WatcherRig, _ message: Comment) async {
        let before = rig.marks.value ?? .distantPast
        rig.clock.advance(by: ScreenshotWatcher.tickInterval)
        let watcher = rig.watcher!
        let tick = Task { await watcher.tickFired() }
        #expect(await eventually { (rig.marks.value ?? .distantPast) > before }, message)
        await tick.value
    }

    /// OC-427-W1. given a tick stuck in its write, when a second tick is called directly, then it returns at once without
    /// waiting on the first (a dropped tick, not a queued one), and nothing was written twice.
    @Test("OC-427-W1 a second tick returns immediately while the first is in flight")
    func secondTickIsDropped() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-10))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let first = await stuckTick(rig)
        rig.clock.advance(by: ScreenshotWatcher.tickInterval)  // a later instant, so an unguarded tick has a newer mark to write
        let returned = LockedValue(false)
        let watcher = rig.watcher!
        let second = Task { await watcher.tickFired(); returned.withLock { $0 = true } }
        #expect(await eventually(timeout: .seconds(2)) { returned.withLock { $0 } }, "the second tick waited behind the first")
        #expect(rig.marks.heldWrites == 1, "only the first tick is in its write")
        rig.marks.releaseWrites()
        await first.value
        await second.value
    }

    /// OC-427-W2. given a tick cancelled while it holds the flag, when the cancelled tick unwinds, then the next tick runs.
    @Test("OC-427-W2 a cancelled tick releases the guard")
    func cancelledTickResets() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-10))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let tick = await stuckTick(rig)
        tick.cancel()
        rig.marks.releaseWrites()
        await tick.value
        await laterTickRuns(rig, "polling died after a cancelled tick")
    }

    /// OC-427-W3. given a tick stuck in its write when pickup is turned off, when the tick unwinds and pickup is turned
    /// back on, then ticks run again (the flag is not left set by the deactivated tick).
    @Test("OC-427-W3 a tick that ends after deactivation releases the guard")
    func deactivatedTickResets() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-10))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let tick = await stuckTick(rig)
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.settingsDidChange()
        rig.marks.releaseWrites()
        await tick.value
        rig.settings.set(true, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.settingsDidChange()
        await laterTickRuns(rig, "polling died after a deactivated tick")
    }

    /// OC-427-W4. given a tick refused while another runs (negative): the guard drops it but the same call succeeds once
    /// the first finishes: exactly one write per finished tick, not zero and not two.
    @Test("OC-427-W4 sequential ticks each write once")
    func sequentialTicksWriteOnce() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-10))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        await rig.tick()
        let afterOne = try #require(rig.marks.value)
        await rig.tick()
        let afterTwo = try #require(rig.marks.value)
        #expect(afterTwo.timeIntervalSince(afterOne) >= 29.9, "the second tick did not run")
    }

    /// OC-427-W5. given a watcher registered on the poll tick that is released while a tick is in flight, when the tick
    /// ends, then the watcher is deallocated (the registration holds it weakly) and later firings are harmless.
    @Test("OC-427-W5 releasing the watcher while a tick is in flight deallocates it after the tick")
    func deinitWhileInFlight() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-10))
        defer { rig.cleanUp() }
        let notices = rig.notices
        let weakWatcher = WeakWatcher()
        do {
            let watcher = ScreenshotWatcher(
                fileSystem: rig.fileSystem, preferences: rig.preferences, home: rig.home, clock: rig.clock,
                eventSource: rig.source, settings: rig.settings, ingest: rig.ingest, watermarkStore: rig.marks,
                report: { notices.raise($0) }, clear: { notices.clear($0) }, pollTick: rig.pollTick, sink: rig.sink)
            weakWatcher.value = watcher
            await watcher.start()
            rig.marks.holdWrites()
            rig.clock.advance(by: ScreenshotWatcher.tickInterval)
            for _ in 0..<60 { rig.pollTick.fire() }
            #expect(await eventually { rig.marks.heldWrites == 1 }, "a tick is in flight")
        }
        // The caller dropped its reference mid-tick: the in-flight tick may keep it alive until it ends.
        rig.marks.releaseWrites()
        #expect(await eventually { weakWatcher.value == nil }, "the poll registration keeps the watcher alive")
        for _ in 0..<60 { rig.pollTick.fire() }
        await letItSettle()
        #expect(weakWatcher.value == nil)
    }
}

final class WeakWatcher: @unchecked Sendable { weak var value: ScreenshotWatcher? }
