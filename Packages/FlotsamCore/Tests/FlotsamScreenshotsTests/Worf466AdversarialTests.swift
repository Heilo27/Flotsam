import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-466 blind QA (Worf): capture off must mean off. A joined live job that capture-pause or pickup-off drops is
// imported by the press that joined it, and only by a press; with no press nothing is imported. Each test names the
// change that turns it red. Expected values are literals.

private final class Result466: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FlotsamResult<Int>?
    func set(_ result: FlotsamResult<Int>) { lock.withLock { stored = result } }
    var value: FlotsamResult<Int>? { lock.withLock { stored } }
}

@Suite("WORF-466: dropped joined jobs, double live imports, bounded presses", .serialized)
struct Worf466AdversarialTests {
    private func files(_ rig: WatcherRig, _ count: Int, prefix: String) throws {
        for i in 0..<count { try rig.shot(in: rig.desktop, "Screenshot \(prefix)-\(i).png") }
    }

    /// 2 jobs in flight and the rest queued from the reconcile (ingests held), nothing joined yet.
    private func heldReconcile(_ rig: WatcherRig, count: Int) async throws {
        await rig.watcher.start()
        try files(rig, count, prefix: "w466")
        rig.ingest.holdIngests()
        await rig.watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.heldIngests == 2 }, "two in flight, the rest queued")
    }

    /// A press whose scan returns while the held reconcile's jobs are pending: it joins every one.
    private func joiningPress(_ rig: WatcherRig, into result: Result466) async {
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        Task { result.set(await watcher.importRecent()) }
        #expect(await eventually { rig.fileSystem.listingIsHeld }, "the press's scan is held")
    }

    // Red when dropQueuedJobs() imports a dropped live job that no press joined (capture off would not mean off): the
    // paused watcher must ingest only the 2 files already in flight, and a press made afterwards finds the other 2.
    @Test("OC-466-NOPRESS: paused, no press joined: the dropped queued jobs import nothing; a later press imports them once")
    func droppedJobsWithNoPressImportNothing() async throws {
        // given: 4 new files, 2 in flight, 2 queued, no press
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        try await heldReconcile(rig, count: 4)
        // when: capture pauses, then the in-flight pair ends
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        await rig.watcher.settingsDidChange()
        rig.ingest.releaseIngests()
        // TASK-480: the pair's end is an async tail (ingest returns, then `finish` writes the watermark, logs
        // `screenshot.imported`, and only then `complete` + `pump` run, in one actor turn with no suspension left). Wait
        // for both pairs' log lines (the last visible step of that tail), not a fixed 150 ms: under load the pair had
        // not always recorded by then, and a count taken before the pump ran passes whether or not the pump imports the
        // dropped pair. The press below is an actor call, so it runs after that last turn.
        let finished = await eventually(timeout: .seconds(10)) {
            rig.ingest.candidates.count == 2 && rig.sink.records.filter { $0.headline == "screenshot.imported" }.count == 2
        }
        #expect(finished, "the 2 in-flight imports must end: \(rig.ingest.names)")
        // then: the queued pair was not imported by anyone
        #expect(rig.ingest.candidates.count == 2, "capture paused: the 2 queued files are not imported")
        // when: the user presses Import Recent (still paused)
        let pressed = await rig.watcher.importRecentWithin()
        // then: the press imports exactly the 2 files that are not in the library, once each, as its own request. A
        // dropped live job that survived (imported by `pump` or joined by the press) is ingested as live pickup
        // (`countsAsCopy` true) or makes the press count 0: either turns this red whatever the timing.
        #expect(pressed == .success(2), "the press must resolve with the 2 files the library did not have")
        #expect(await eventually { rig.ingest.candidates.count == 4 }, "the press ingested the 2 remaining files")
        let candidates = rig.ingest.candidates
        #expect(candidates.count == 4, "each of the 4 files ingested once")
        #expect(Set(rig.ingest.names).count == 4, "no file ingested twice")
        #expect(candidates.prefix(2).allSatisfy { $0.countsAsCopy }, "the first pair was live pickup")
        #expect(candidates.suffix(2).allSatisfy { !$0.countsAsCopy }, "the last pair was the press's own import, not live pickup")
    }

    // Red when only the first joined press is credited with the handed-over job (a second press that joined the same
    // dropped job hangs or reports 2): both presses must say 4 and each file goes in once.
    @Test("OC-466-TWOPRESS: two presses joined the same dropped jobs: both resolve with 4, 4 ingests")
    func twoPressesJoinedTheSameDroppedJobs() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        try await heldReconcile(rig, count: 4)
        let a = Result466()
        let b = Result466()
        await joiningPress(rig, into: a)
        rig.fileSystem.releaseListing()
        await letItSettle()
        let watcher = rig.watcher!
        Task { b.set(await watcher.importRecent()) }
        await letItSettle()
        // when: pickup is turned off, then the in-flight pair ends
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.settingsDidChange()
        rig.ingest.releaseIngests()
        // then
        #expect(await eventually(timeout: .seconds(10)) { a.value != nil && b.value != nil }, "both presses must resolve")
        #expect(a.value == .success(4))
        #expect(b.value == .success(4))
        await letItSettle()
        #expect(rig.ingest.candidates.count == 4, "each file ingested once")
        #expect(Set(rig.ingest.names).count == 4)
    }

    // Red when the handed-over jobs go in as live copy events (countsAsCopy true) or the pause leaves them out of the
    // press's count: 3 files, 2 in flight + 1 queued; the queued one is the single dropped job (boundary n = 1).
    @Test("OC-466-ONE: one dropped job under a press (pickup off): Imported 3, the handed-over file is not a copy event")
    func oneDroppedJobIsImportedAsBackfill() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        try await heldReconcile(rig, count: 3)
        let done = Result466()
        await joiningPress(rig, into: done)
        rig.fileSystem.releaseListing()
        await letItSettle()
        rig.settings.set(false, for: SettingKeys.screenshotsEnabled)
        await rig.watcher.settingsDidChange()
        rig.ingest.releaseIngests()
        #expect(await eventually(timeout: .seconds(10)) { done.value != nil }, "the press must resolve")
        #expect(done.value == .success(3))
        await letItSettle()
        #expect(rig.ingest.candidates.count == 3)
        #expect(rig.ingest.candidates.filter { !$0.countsAsCopy }.count == 1, "exactly the one dropped file goes in as backfill")
    }

    // Red when the first import of a path is lost once the path has a second import (last write wins: Imported 1), or
    // when ended imports are counted only while the path is still pending.
    @Test("OC-466-TWICE-ENDED: the same path live-imported twice, both ended before the scan returns: Imported 2")
    func twoEndedImportsOfOnePathBothCount() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let name = "Screenshot twice-ended.png"
        let path = try rig.shot(in: rig.desktop, name)
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let done = Result466()
        Task { done.set(await watcher.importRecent()) }
        #expect(await eventually { rig.fileSystem.listingIsHeld })
        await watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.candidates.count == 1 }, "first import ended")
        await letItSettle()
        // when: new bytes land at the same path and the second live import ends too
        rig.clock.advance(by: 5)
        try FileManager.default.removeItem(at: path)
        try rig.shot(in: rig.desktop, name)
        rig.event(path)
        #expect(await eventually { rig.ingest.candidates.count == 2 }, "second import ended")
        await letItSettle()
        rig.fileSystem.releaseListing()
        // then
        #expect(await eventually(timeout: .seconds(10)) { done.value != nil }, "the press must resolve")
        #expect(done.value == .success(2))
        await letItSettle()
        #expect(rig.ingest.candidates.count == 2, "the press ingested nothing itself")
    }

    // Red when every recorded live import counts as created: the second import of the same bytes creates nothing, so
    // the press says 1, not 2.
    @Test("OC-466-DEDUPED: second live import of the same path is a dedupe: counted once, not twice")
    func dedupedSecondImportIsNotCounted() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let name = "Screenshot dedupe.png"
        let path = try rig.shot(in: rig.desktop, name)
        let bytes = try Data(contentsOf: path)
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let done = Result466()
        Task { done.set(await watcher.importRecent()) }
        #expect(await eventually { rig.fileSystem.listingIsHeld })
        await watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.candidates.count == 1 })
        await letItSettle()
        rig.clock.advance(by: 5)
        try FileManager.default.removeItem(at: path)
        let again = try rig.shot(in: rig.desktop, name)
        try bytes.write(to: again)
        rig.event(again)
        #expect(await eventually { rig.ingest.candidates.count == 2 }, "second import ended")
        await letItSettle()
        rig.fileSystem.releaseListing()
        #expect(await eventually(timeout: .seconds(10)) { done.value != nil }, "the press must resolve")
        #expect(done.value == .success(1))
    }

    // Red when `finishes` / `importRecentWithin` wait without a bound (this test would hang the suite) or report a hung
    // press as resolved. A real press is kept hanging by holding every ingest.
    @Test("OC-466-BOUND: a press that cannot resolve returns nil within the bound instead of hanging")
    func hungPressFailsCleanly() async throws {
        // given: one file whose ingest is held forever
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        try rig.shot(in: rig.desktop, "Screenshot hang.png")
        rig.ingest.holdIngests()
        // when
        let started = ContinuousClock.now
        let result = await rig.watcher.importRecentWithin(.milliseconds(400))
        // then: nil (not a count), and it came back near the bound, not after the 10 s default
        #expect(result == nil, "a hung press reports nothing")
        #expect(ContinuousClock.now - started < .seconds(3), "the bound is honoured")
        // and the same press resolves normally once released, so a slow press is not mistaken for a hung one
        // The abandoned press is still running, so the file's import is whatever it left. Let it finish, then add a file
        // nothing is running for: the press must now come back with that one (TASK-509: pressing straight after the
        // release raced the abandoned press's import, which counted 0 whenever it had already finished).
        rig.ingest.releaseIngests()
        #expect(await rig.watcher.untilIdle(), "the released import never ended")
        try rig.shot(in: rig.desktop, "Screenshot after.png")
        #expect(await rig.watcher.importRecentWithin() == .success(1))
    }
}
