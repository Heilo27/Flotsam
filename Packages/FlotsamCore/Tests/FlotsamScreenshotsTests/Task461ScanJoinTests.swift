import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-461 (Worf review): a press counts every file its own scan finds new to the library. A file live pickup is still
// working on when the press's scan returns is joined (its result counts when it ends); one live pickup imported after
// the press began is counted from the record the watcher keeps for open presses; one imported before the press began
// is already in the library and is neither ingested again nor counted.

@Suite("TASK-461: a press counts what its own scan finds", .serialized)
struct Task461ScanJoinTests {
    private func makeFiles(_ rig: WatcherRig, count: Int) throws {
        for i in 0..<count { try rig.shot(in: rig.desktop, "Screenshot join-\(i).png") }
    }

    @Test("scan returns while the reconcile's jobs are queued and in flight: joined, Imported 4, 4 ingests")
    func scanReturnsWhileJobsArePending() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        try makeFiles(rig, count: 4)
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let press = Task { await watcher.importRecent() }
        #expect(await eventually { rig.fileSystem.listingIsHeld }, "the press's scan is held")
        // Nothing is pending yet, so only a join made when the scan returns can see these files.
        rig.ingest.holdIngests()
        await watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.heldIngests == 2 }, "two jobs in flight, two queued behind them")
        rig.fileSystem.releaseListing()
        await letItSettle()
        rig.ingest.releaseIngests()
        let done = Outcome()
        Task { done.set(await press.value) }
        #expect(await eventually { done.value != nil }, "the press resolves once the joined jobs end")
        #expect(done.value == .success(4))
        await letItSettle()
        #expect(rig.ingest.candidates.count == 4, "each file ingested once")
    }

    @Test("press lands while a live import is finishing (watermark write pending): ingested once, already in the library")
    func pressDuringTheTailOfALiveImport() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        try makeFiles(rig, count: 1)
        rig.ingest.holdIngests()
        await rig.watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.heldIngests == 1 })
        rig.marks.holdWrites()
        rig.ingest.releaseIngests()
        // The import has ended and left `pending`; the job is suspended in `settle`, before `complete`.
        #expect(await eventually { rig.marks.heldWrites == 1 }, "the live job is in its tail")
        let watcher = rig.watcher!
        let press = Task { await watcher.importRecent() }
        await letItSettle()
        rig.marks.releaseWrites()
        let done = Outcome()
        Task { done.set(await press.value) }
        #expect(await eventually { done.value != nil }, "the press must not hang")
        #expect(done.value == .success(0), "the file was in the library before the press began")
        await letItSettle()
        #expect(rig.ingest.candidates.count == 1, "the press must not ingest it again")
    }
}

/// The press's result once it has one; a press that never resolves fails the test instead of hanging it.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FlotsamResult<Int>?
    func set(_ result: FlotsamResult<Int>) { lock.withLock { stored = result } }
    var value: FlotsamResult<Int>? { lock.withLock { stored } }
}
