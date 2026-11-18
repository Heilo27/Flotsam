import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-461 QA (Worf): RED test. The press joins only what is `pending` when it looks (entry snapshot, or when its scan
// returns). A press that BEGAN before the reconcile queued the files, whose own folder scan returns after the
// reconcile's imports have already ended, finds them in `ingestedLive`, skips them and reports "Imported 0" while the
// library gained 4 files during the press: the TASK-456 symptom, in the interleaving "reconcile starts and finishes
// inside the press's scan". Also kills the surviving mutation "remove the entry-snapshot join" (the scan-time join
// alone passes every TASK-461 test).

@MainActor
private final class MidScanHUDLog { var messages: [String] = [] }

@Suite("WORF-461: press whose scan outlives the reconcile's imports", .serialized)
struct Worf461MidScanTests {
    @Test("OC-461-MIDSCAN: press starts, reconcile queues+finishes 4 files, press scan returns: Imported 4, 4 ingests")
    func reconcileRunsInsideThePressScan() async throws {
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-60))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        for i in 0..<4 { try rig.shot(in: rig.desktop, "Screenshot mid-\(i).png") }
        rig.fileSystem.holdNextListing()
        let watcher = rig.watcher!
        let press = Task { await watcher.importRecent() }
        #expect(await eventually { rig.fileSystem.listingIsHeld }, "the press's scan is held")
        await watcher.didBecomeActive()
        #expect(await eventually { rig.ingest.candidates.count == 4 }, "the reconcile imported all four")
        await letItSettle()
        rig.fileSystem.releaseListing()
        let result = await press.value
        await letItSettle()
        #expect(rig.ingest.candidates.count == 4, "each file ingested once")
        #expect(result == .success(4), "the press ran while 4 files arrived; it must not say Imported 0")
    }
}
