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
        await rig.watcher.didBecomeActive()
        let log = await RaceHUDLog()
        await rig.watcher.importRecentAnnouncing { m in log.messages.append(m) }
        #expect(await eventually { Set(rig.ingest.names).count == 6 }, "all six files reached the library")
        #expect(await log.messages == ["Imported 6"], "the HUD must not claim 0 for a press that coincided with 6 imports")
    }
}
