import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-461 second QA pass (Worf): the press/live-pickup join paths the builder's own tests do not reach. Each test names
// the code change that turns it red. Expected values are literals; a press that never resolves fails the test instead
// of hanging it.

private final class PressOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FlotsamResult<Int>?
    func set(_ result: FlotsamResult<Int>) { lock.withLock { stored = result } }
    var value: FlotsamResult<Int>? { lock.withLock { stored } }
}

@Suite("WORF-461b: press/live join paths", .serialized)
struct Worf461SecondPassTests {
    private func files(_ rig: WatcherRig, _ count: Int, prefix: String) throws {
        for i in 0..<count { try rig.shot(in: rig.desktop, "Screenshot \(prefix)-\(i).png") }
    }

    /// Starts a press whose scan is held, fills the queue through the reconcile with ingests held (2 in flight, rest
    /// queued), then releases the scan so the press joins every file.
    private func pressJoiningHeldJobs(_ rig: WatcherRig, files count: Int) async -> (Task<FlotsamResult<Int>, Never>, PressOutcome) {
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let press = Task { await watcher.importRecent() }
        #expect(await eventually { rig.fileSystem.listingIsHeld }, "the press's scan is held")
        rig.ingest.holdIngests()
        await watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.heldIngests == 2 }, "two in flight, the rest queued")
        rig.fileSystem.releaseListing()
        await letItSettle()
        let done = PressOutcome()
        Task { done.set(await press.value) }
        return (press, done)
    }

    // Red when `complete()` stops crediting `joined` presses for a job that dropQueuedJobs() removes (press hangs), or
    // credits a dropped job as created (count != 2).
    @Test("OC-461-DROP: capture paused drops the queued live jobs a press joined: the press still resolves, Imported 2")
    func queuedJobsDroppedUnderAJoinedPress() async throws {
        // given: 4 new files, reconcile has 2 in flight + 2 queued, the press joined all 4
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        try files(rig, 4, prefix: "drop")
        let (_, done) = await pressJoiningHeldJobs(rig, files: 4)
        // when: capture mode pauses (FR-002-05 drops the 2 queued jobs), then the 2 in-flight imports end
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        await rig.watcher.settingsDidChange()
        rig.ingest.releaseIngests()
        // then: no hang; only the 2 files that were really imported count
        #expect(await eventually { done.value != nil }, "the press must resolve")
        #expect(done.value == .success(2))
        await letItSettle()
        #expect(rig.ingest.candidates.count == 2, "the dropped jobs ingest nothing")
    }

    // Red when a failure of a live job the press joined is not carried to the press (it would say Imported 0).
    @Test("OC-461-FAIL: every joined live job fails to store: the press reports the failure, never Imported 0")
    func joinedJobsAllFail() async throws {
        // given: 2 new files whose storage fails; the reconcile has both in flight when the press's scan returns
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let failure = FlotsamError(.stoDb001, "the library could not be written")
        for name in ["Screenshot fail-a.png", "Screenshot fail-b.png"] {
            try rig.shot(in: rig.desktop, name)
            rig.ingest.fail(name, with: failure)
        }
        let (_, done) = await pressJoiningHeldJobs(rig, files: 2)
        // when
        rig.ingest.releaseIngests()
        // then
        #expect(await eventually { done.value != nil }, "the press must resolve")
        #expect(done.value == .failure(failure))
    }

    // Red when `complete()` credits only the job's own batch and not the presses that joined a backfill job.
    @Test("OC-461-OVERLAP: two presses call importRecent at once; B joins A's in-flight jobs: both resolve to 4, 4 ingests")
    func overlappingPressesBothResolve() async throws {
        // given: press A has 4 files in its own jobs (2 in flight, 2 queued), ingests held
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        try files(rig, 4, prefix: "overlap")
        rig.ingest.holdIngests()
        let watcher = rig.watcher!
        let a = PressOutcome()
        let b = PressOutcome()
        Task { a.set(await watcher.importRecent()) }
        #expect(await eventually { rig.ingest.heldIngests == 2 })
        // when: B starts, its scan lists the same 4 files while they are pending
        Task { b.set(await watcher.importRecent()) }
        await letItSettle()
        rig.ingest.releaseIngests()
        // then
        #expect(await eventually { a.value != nil && b.value != nil }, "both presses must resolve")
        #expect(a.value == .success(4))
        #expect(b.value == .success(4))
        await letItSettle()
        #expect(rig.ingest.candidates.count == 4, "each file ingested once")
    }

    // Red when a press counts a live import its own scan did not list (every liveImports entry added to the total, or the
    // removed entry-snapshot join): the 10-day file is outside the press's 7-day window, so the press finds only one.
    @Test("OC-461-WINDOW: a reconcile import outside the press's retention window is not counted by the press")
    func importOutsideTheWindowIsNotCounted() async throws {
        // given: retention 7 days; the reconcile (watermark 30 days back) imports a 2-day and a 10-day file
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-30 * 86_400))
        defer { rig.cleanUp() }
        rig.settings.set(RetentionPreset.d7, for: SettingKeys.storageRetention)
        try rig.shot(in: rig.desktop, "Screenshot two-day.png", born: Date().addingTimeInterval(-2 * 86_400))
        try rig.shot(in: rig.desktop, "Screenshot ten-day.png", born: Date().addingTimeInterval(-10 * 86_400))
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let done = PressOutcome()
        Task { done.set(await watcher.importRecent()) }
        #expect(await eventually { rig.fileSystem.listingIsHeld })
        // when: the launch reconcile (watermark 30 days back) imports both while the press scans
        await watcher.start()
        #expect(await eventually { rig.ingest.candidates.count == 2 }, "the reconcile imported both: \(rig.ingest.names)")
        await letItSettle()
        rig.fileSystem.releaseListing()
        // then: the press's scan lists only the 2-day file
        #expect(await eventually { done.value != nil })
        #expect(done.value == .success(1))
        await letItSettle()
        #expect(rig.ingest.candidates.count == 2, "nothing ingested twice")
    }

    // Red when a press's record of live imports leaks into the next press, or a press re-ingests what live pickup did.
    @Test("OC-461-LEAK: press 1 counted 4 live imports; press 2 right after finds none new: Imported 0, still 4 ingests")
    func nothingLeaksIntoTheNextPress() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        try files(rig, 4, prefix: "leak")
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let first = PressOutcome()
        Task { first.set(await watcher.importRecent()) }
        #expect(await eventually { rig.fileSystem.listingIsHeld })
        await watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.candidates.count == 4 })
        await letItSettle()
        rig.fileSystem.releaseListing()
        #expect(await eventually { first.value != nil })
        #expect(first.value == .success(4))
        // when
        let second = await watcher.importRecent()
        // then
        #expect(second == .success(0))
        #expect(rig.ingest.candidates.count == 4)
    }

    // Red when finish() leaves a finished job's joiners registered (`joiners.removeValue` -> a plain read): the next job
    // for the same path would credit the still-open press a second time and resolve it while B is still in flight.
    @Test("OC-461-STALE: a press joined A and B; A ends and is imported again while B is in flight: the press waits for B")
    func finishedJobsJoinersAreSpent() async throws {
        // given: A and B in flight and held by name, the press joined both
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let a = try rig.shot(in: rig.desktop, "Screenshot stale-a.png")
        try rig.shot(in: rig.desktop, "Screenshot stale-b.png")
        rig.ingest.holdIngest(named: "Screenshot stale-a.png")
        rig.ingest.holdIngest(named: "Screenshot stale-b.png")
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let done = PressOutcome()
        Task { done.set(await watcher.importRecent()) }
        #expect(await eventually { rig.fileSystem.listingIsHeld })
        await watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.heldIngests == 2 })
        rig.fileSystem.releaseListing()
        await letItSettle()
        // when: A ends, then a new file lands at A's path and is imported live while B is still held
        rig.ingest.releaseIngest(named: "Screenshot stale-a.png")
        #expect(await eventually { rig.ingest.candidates.count == 1 }, "A ended")
        await letItSettle()
        rig.clock.advance(by: 5)
        try FileManager.default.removeItem(at: a)
        try rig.shot(in: rig.desktop, "Screenshot stale-a.png")
        rig.event(a)
        #expect(await eventually { rig.ingest.candidates.count == 2 }, "the second A was imported: \(rig.ingest.names)")
        await letItSettle()
        // then: the press still waits for B; once B ends it reports the two files it found
        #expect(done.value == nil, "the press resolved before B ended: \(String(describing: done.value))")
        rig.ingest.releaseIngest(named: "Screenshot stale-b.png")
        #expect(await eventually { done.value != nil }, "the press must resolve")
        #expect(done.value == .success(2))
    }
}
