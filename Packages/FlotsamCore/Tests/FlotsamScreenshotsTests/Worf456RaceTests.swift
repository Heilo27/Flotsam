import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-456 QA (Worf): Import Recent coinciding with the `didBecomeActive` reconcile scan. Pressing the button activates
// the app, so the reconcile queues the same new files as live pickup; the press must count those imports ("Imported 6"),
// not skip them as already pending ("Imported 0") while the library gains the files.

@MainActor
private final class RaceHUDLog { var messages: [String] = [] }

@Suite("WORF-456: Import Recent racing the didBecomeActive reconcile scan", .serialized)
struct Worf456RaceTests {
    @Test("OC-456-RACE: 6 new files, reconcile queues them first: the press reports Imported 6, not Imported 0")
    func pressAfterReconcileQueuedTheFiles() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        for i in 0..<6 { try rig.shot(in: rig.desktop, "Screenshot race-\(i).png") }
        // The reconcile queues the files first and its ingests stay open, so the press cannot reach the library before
        // the files do: the earlier version let the reconcile finish while the press was still getting started (a
        // fixed head start, lost under load), which made the press correctly count fewer than 6.
        rig.ingest.holdIngests()
        await rig.watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.heldIngests == 2 }, "the reconcile queued the files first: two in flight, four queued")
        // when: the press starts; its batch is registered before its scan, so a held scan proves it has begun
        rig.fileSystem.holdNextListing()
        let log = await RaceHUDLog()
        let watcher = rig.watcher!
        let pressEnded = Handoff<Bool>()
        Task {
            await watcher.importRecentAnnouncingWithin { m in log.messages.append(m) }
            pressEnded.set(true)
        }
        #expect(await eventually { rig.fileSystem.listingIsHeld }, "the press has begun and its scan is held")
        rig.fileSystem.releaseListing()
        rig.ingest.releaseIngests()
        // then: the press resolves, all six files reached the library once, and the HUD counts all six
        #expect(await eventually(timeout: .seconds(15)) { pressEnded.value == true }, "the press must resolve")
        #expect(await eventually { Set(rig.ingest.names).count == 6 }, "all six files reached the library")
        #expect(rig.ingest.names.count == 6, "each ingested once")
        #expect(await log.messages == ["Imported 6"], "the HUD must not claim 0 for a press that coincided with 6 imports")
    }
}
