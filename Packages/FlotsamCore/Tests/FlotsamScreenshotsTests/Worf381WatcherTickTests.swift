import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

private func realPath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

/// TASK-381: the watcher's 30 s re-resolve is a registration on `PollTick` (every 60th tick). The existing watcher
/// tests call `tickFired()` directly, so none of them proves the registration; these drive `rig.pollTick`.
@Suite("ScreenshotWatcher on the shared poll tick", .serialized)
struct Worf381WatcherTickTests {
    /// OC-381-40. given a watcher on folder A and the location changed to B, when 59 ticks fire, then it is still on A;
    /// when the 60th fires, then it is rebuilt on B. Red if the watcher registers for any other period (every(1) moves
    /// at tick 1, every(5) at tick 10), never registers, or registers a different action.
    @Test("OC-381-40 the folder is re-resolved on the 60th tick, not before")
    func reresolveRunsOnTheSixtiethTick() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-10))
        defer { rig.cleanUp() }
        let first = try rig.temp.folder("Pictures/First")
        let second = try rig.temp.folder("Pictures/Second")
        rig.use(first)
        await rig.watcher.start()
        #expect(rig.pollTick.registrationCount == 1)

        rig.use(second)
        for _ in 0..<59 { rig.pollTick.fire() }
        await letItSettle()
        #expect(rig.source.running.map { realPath($0.folder) } == [realPath(first)], "no re-resolve before tick 60")

        rig.pollTick.fire()
        #expect(await eventually { rig.source.running.map { realPath($0.folder) } == [realPath(second)] })
        #expect(rig.pollTick.registrationCount == 1, "still exactly one registration after a rebuild")
    }
}

/// TASK-427 D2: the tick registration spawns a `Task` per firing, and `tickFired` suspends (folder listing, the folder
/// access prompt, the watermark write), so a slow tick used to run alongside the next one.
@Suite("ScreenshotWatcher tick serialization", .serialized)
struct Task427WatcherTickOverlapTests {
    /// OC-427-10. given a tick stuck in its watermark write, when the next 30 s tick fires, then it does not run
    /// alongside it (a second watermark write would be held too); when the first finishes, the following tick runs.
    @Test("OC-427-10 a tick that fires while the previous one is unfinished does not overlap it")
    func ticksDoNotOverlap() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-10))
        defer { rig.cleanUp() }
        let folder = try rig.temp.folder("Pictures/Shots")
        rig.use(folder)
        await rig.watcher.start()
        let baseline = rig.marks.value

        rig.marks.holdWrites()
        rig.clock.advance(by: ScreenshotWatcher.tickInterval)
        for _ in 0..<60 { rig.pollTick.fire() }
        #expect(await eventually { rig.marks.heldWrites == 1 }, "tick 1 is stuck in its watermark write")

        rig.clock.advance(by: ScreenshotWatcher.tickInterval)
        for _ in 0..<60 { rig.pollTick.fire() }
        let overlapped = await eventually(timeout: .milliseconds(300)) { rig.marks.heldWrites > 1 }
        #expect(!overlapped, "tick 2 ran while tick 1 was still unfinished")

        rig.marks.releaseWrites()
        #expect(await eventually { rig.marks.heldWrites == 0 && (rig.marks.value ?? .distantPast) > (baseline ?? .distantPast) })

        // Not wedged: a later tick runs.
        let afterFirst = rig.marks.value
        rig.clock.advance(by: ScreenshotWatcher.tickInterval)
        for _ in 0..<60 { rig.pollTick.fire() }
        #expect(await eventually { (rig.marks.value ?? .distantPast) > (afterFirst ?? .distantPast) }, "a later tick still runs")
    }
}
