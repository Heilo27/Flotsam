import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// WORF-517 (blind QA of TASK-517): a press that `stop()` overtakes is abandoned, ingests nothing and resolves as paused.
// Mutation map (each must turn exactly the named test red, by assertion and never by hang; every wait is bounded):
//   M1 drop `if stopped { return abandonPress(id) }` after the listing      -> OC-WORF517-05 (a refused listing after stop())
//   M2 drop the same guard after `markAccessGranted`                         -> OC-WORF517-01
//   M3 `abandonPress` returns .success(0)                                    -> OC-WORF517-01, 03
//   M4 `abandonPress` never returns (parks forever)                          -> bounded waits in 01, 02, 03
//   M5 guards inverted/always true (`if true`)                               -> OC-WORF517-04 (never-stopped press)

@MainActor
private final class HUDLog517 {
    var messages: [String] = []
}

@Suite("WORF-517: press overtaken by stop()", .serialized, .timeLimit(.minutes(1)))
struct Worf517AdversarialTests {
    /// The rig's watcher rebuilt so `clear(.sspPrm001)` records and then parks at `gate` while it is closed.
    private func watcherHoldingAccessClear(_ rig: WatcherRig, gate: WorfGate) -> ScreenshotWatcher {
        let notices = rig.notices
        return ScreenshotWatcher(
            fileSystem: rig.fileSystem, preferences: rig.preferences, home: rig.home, clock: rig.clock,
            eventSource: rig.source, settings: rig.settings, ingest: rig.ingest, watermarkStore: rig.marks,
            report: { notices.raise($0) },
            clear: { code in
                notices.clear(code)
                if code == .sspPrm001 { await gate.pass() }
            },
            pollTick: rig.pollTick, sink: rig.sink)
    }

    private func isPaused(_ result: FlotsamResult<Int>?) -> Bool {
        guard let result, case .failure(let error) = result else { return false }
        return error.code == .sspIo003
    }

    /// OC-WORF517-01. given a press that read a folder it had been refused and is parked clearing that refusal (pickup
    /// off), when `stop()` runs and returns and the clear then finishes, then the press fails as paused and nothing is
    /// ingested or running. Boundary: 2 files listed, 0 ingested. Red if the guard after `markAccessGranted` is dropped
    /// (the press enqueues its 2 files after stop() returned) or abandonPress resolves as a success.
    @Test("OC-WORF517-01 a press parked clearing the refusal when stop() runs ingests nothing and fails as paused")
    func stopDuringAccessClear() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let gate = WorfGate()
        let watcher = watcherHoldingAccessClear(rig, gate: gate)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        _ = await watcher.importRecentWithin()
        #expect(rig.notices.standing(.sspPrm001), "the refusal was not raised: the setup is wrong")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.desktop.path)
        try rig.shot(in: rig.desktop, "Screenshot clear-a.png")
        try rig.shot(in: rig.desktop, "Screenshot clear-b.png")

        gate.close()
        let resolved = Handoff<FlotsamResult<Int>>()
        Task { resolved.set(await watcher.importRecent()) }
        #expect(await eventually(timeout: .seconds(20)) { gate.waiting == 1 }, "the press never parked in the clear")
        let stopReturned = await finishes { await watcher.stop() }
        let runningAtReturn = await watcher.importsRunning
        gate.open()
        #expect(stopReturned, "stop() hung")
        #expect(await eventually(timeout: .seconds(20)) { resolved.value != nil }, "the press never resolved after stop()")
        #expect(isPaused(resolved.value), "expected a paused failure, got \(String(describing: resolved.value))")
        #expect(await watcher.untilIdle(), "imports never ended")
        await letItSettle()
        #expect(runningAtReturn == 0)
        #expect(rig.ingest.names.isEmpty, "a press parked in the access clear ingested after stop(): \(rig.ingest.names)")
        #expect(await watcher.importsRunning == 0)
    }

    /// OC-WORF517-02. given press A parked in its listing and press B already importing 2 held files, when `stop()` is
    /// called, A's listing returns, and B's ingests are released, then A fails as paused, B succeeds with 2, stop()
    /// returns only after B's imports end, and each file is ingested exactly once (count delta 2, identities both).
    /// Red if A (not B) is the one that still ingests (guard dropped: names has 4 entries) or if stop() drops B's accepted
    /// imports (survivor identity lost).
    @Test("OC-WORF517-02 concurrent presses across stop(): the overtaken one is dropped, the accepted one completes once")
    func concurrentPressesAcrossStop() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let one = try rig.shot(in: rig.desktop, "Screenshot cp-a.png").lastPathComponent
        let two = try rig.shot(in: rig.desktop, "Screenshot cp-b.png").lastPathComponent
        // pickup is on and its start-up scan may already be importing; wait it out so only presses remain
        #expect(await rig.watcher.untilIdle())
        let before = rig.ingest.names.count
        let watcher = rig.watcher!
        rig.fileSystem.holdNextListing()
        let resultA = Handoff<FlotsamResult<Int>>()
        Task { resultA.set(await watcher.importRecent()) }
        #expect(await eventually(timeout: .seconds(20)) { rig.fileSystem.listingIsHeld }, "press A never reached its listing")
        rig.ingest.holdIngests()
        let resultB = Handoff<FlotsamResult<Int>>()
        Task { resultB.set(await watcher.importRecent()) }
        #expect(await eventually(timeout: .seconds(20)) { rig.ingest.heldIngests == 2 }, "press B never reached its ingests")
        let stopped = Handoff<Int>()
        Task { await watcher.stop(); stopped.set(await watcher.importsRunning) }
        await letItSettle()
        #expect(stopped.value == nil, "stop() returned while press B's imports were held")
        rig.fileSystem.releaseListing()
        #expect(await eventually(timeout: .seconds(20)) { resultA.value != nil }, "press A never resolved")
        #expect(isPaused(resultA.value), "press A: \(String(describing: resultA.value))")
        #expect(stopped.value == nil, "stop() returned before press B's imports ended")
        rig.ingest.releaseIngests()
        #expect(await eventually(timeout: .seconds(20)) { stopped.value != nil && resultB.value != nil }, "stop()/press B never finished")
        #expect(stopped.value == 0)
        if case .success(let created)? = resultB.value { #expect(created == 2) } else {
            Issue.record("press B should succeed with 2: \(String(describing: resultB.value))")
        }
        let names = Array(rig.ingest.names.dropFirst(before))
        #expect(names.sorted() == [one, two].sorted(), "each file exactly once, got \(names)")
    }

    /// OC-WORF517-03. given the HUD entry point (`importRecentAnnouncing`) with its press parked in the listing, when
    /// `stop()` runs and the listing returns, then the HUD gets exactly one message, the paused one (the same as a press
    /// made after stop()), and the run ends. Red if the abandoned press resolves as a count ("Imported 0/2") or never ends.
    @Test("OC-WORF517-03 an announcing press overtaken by stop() shows the paused message once")
    func announcingPressOvertaken() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        try rig.shot(in: rig.desktop, "Screenshot hud-a.png")
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let log = await HUDLog517()
        let ended = Handoff<Bool>()
        Task {
            await watcher.importRecentAnnouncing { message in log.messages.append(message) }
            ended.set(true)
        }
        #expect(await eventually(timeout: .seconds(20)) { rig.fileSystem.listingIsHeld }, "the press never reached its listing")
        await watcher.stop()
        rig.fileSystem.releaseListing()
        #expect(await eventually(timeout: .seconds(20)) { ended.value == true }, "the announcing press never ended")
        let paused = FlotsamStrings.message(for: FlotsamError(.sspIo003, "paused"))
        #expect(await log.messages == [paused])
        #expect(rig.ingest.names.isEmpty, "ingested \(rig.ingest.names)")
    }

    /// OC-WORF517-04. given a watcher never stopped, when a press is parked in its listing and released, then it succeeds
    /// with the count of both files and each is ingested once. Boundary 2 files. Red if either new guard fires on a
    /// watcher that was not stopped.
    @Test("OC-WORF517-04 a never-stopped press parked in its listing still imports both files once")
    func neverStoppedPressUnchanged() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        let one = try rig.shot(in: rig.desktop, "Screenshot ok-a.png").lastPathComponent
        let two = try rig.shot(in: rig.desktop, "Screenshot ok-b.png").lastPathComponent
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let result = Handoff<FlotsamResult<Int>>()
        Task { result.set(await watcher.importRecent()) }
        #expect(await eventually(timeout: .seconds(20)) { rig.fileSystem.listingIsHeld }, "the press never reached its listing")
        rig.fileSystem.releaseListing()
        #expect(await eventually(timeout: .seconds(20)) { result.value != nil }, "the press never resolved")
        if case .success(let created)? = result.value { #expect(created == 2) } else {
            Issue.record("expected success(2): \(String(describing: result.value))")
        }
        #expect(rig.ingest.names.sorted() == [one, two].sorted())
    }

    /// OC-WORF517-05. given a press parked in its listing that the folder then refuses (permission), when `stop()` runs
    /// and the listing returns, then the press fails as paused and raises no SSP-PRM-001: nothing is reported after
    /// stop() returned (stop() has already cleared the watcher's conditions, so a notice raised now would stand forever).
    /// Boundary: 0 notices raised. Red if the listing's failure is handled (access-denied raised) before the stopped check.
    @Test("OC-WORF517-05 a press whose listing is refused after stop() raises no notice and fails as paused")
    func refusedListingAfterStop() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        try rig.shot(in: rig.desktop, "Screenshot refused-a.png")
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let resolved = Handoff<FlotsamResult<Int>>()
        Task { resolved.set(await watcher.importRecent()) }
        #expect(await eventually(timeout: .seconds(20)) { rig.fileSystem.listingIsHeld }, "the press never reached its listing")
        await watcher.stop()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.desktop.path)
        rig.fileSystem.releaseListing()
        #expect(await eventually(timeout: .seconds(20)) { resolved.value != nil }, "the press never resolved after stop()")
        #expect(isPaused(resolved.value), "expected paused, got \(String(describing: resolved.value))")
        #expect(rig.notices.raised(.sspPrm001) == 0, "a notice was raised after stop(): \(rig.notices.entries)")
        #expect(rig.ingest.names.isEmpty)
    }
}
