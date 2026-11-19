import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-461 bug report (Worf QA of TASK-456): a reconcile scan followed by the press's backfill ingested the same files
// twice (4 files, 8 ingests). Each file must reach the ingest pipeline once, whether the press arrives while the
// reconcile's jobs are in flight or after they ended.

@MainActor
private final class OnceHUDLog { var messages: [String] = [] }

@Suite("TASK-461: reconcile + Import Recent ingest each file exactly once", .serialized)
struct Task461ExactlyOnceTests {
    private func makeFiles(_ rig: WatcherRig, count: Int) throws {
        for i in 0..<count { try rig.shot(in: rig.desktop, "Screenshot once-\(i).png") }
    }

    @Test("press after the reconcile's imports ended: 4 files, 4 ingests")
    func pressAfterReconcileEnded() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        try makeFiles(rig, count: 4)
        await rig.watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.candidates.count == 4 })
        // The last import ends (and leaves `pending`) a moment after its ingest returns.
        #expect(await rig.watcher.untilIdle())
        #expect(await rig.watcher.importRecentWithin() == .success(0))
        await letItSettle()
        #expect(rig.ingest.candidates.count == 4, "the press must not ingest what the reconcile already did")
    }

    @Test("press while the reconcile's imports are in flight: 4 ingests and Imported 4")
    func pressDuringReconcile() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        rig.ingest.holdIngests()
        await rig.watcher.start()
        try makeFiles(rig, count: 4)
        await rig.watcher.didBecomeActive()
        let log = await OnceHUDLog()
        let watcher = rig.watcher!
        let pressBegan = await pressWhileJobsHeld(rig) { await watcher.importRecentAnnouncing { m in log.messages.append(m) } }
        #expect(pressBegan, "the press must resolve")
        #expect(await rig.watcher.untilIdle())
        #expect(await log.messages == ["Imported 4"])
        #expect(rig.ingest.candidates.count == 4)
    }

    @Test("pressing twice still ingests nothing twice for files live pickup imported")
    func pressTwice() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        rig.ingest.holdIngests()
        await rig.watcher.start()
        try makeFiles(rig, count: 4)
        await rig.watcher.didBecomeActive()
        let first = Handoff<FlotsamResult<Int>>()
        let watcher = rig.watcher!
        #expect(await pressWhileJobsHeld(rig) { first.set(await watcher.importRecent()) }, "the first press must resolve")
        #expect(first.value == .success(4))
        #expect(await rig.watcher.importRecentWithin() == .success(0))
        #expect(await rig.watcher.untilIdle())
        #expect(rig.ingest.candidates.count == 4)
    }
}
