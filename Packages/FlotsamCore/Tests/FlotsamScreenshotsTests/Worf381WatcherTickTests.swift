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
