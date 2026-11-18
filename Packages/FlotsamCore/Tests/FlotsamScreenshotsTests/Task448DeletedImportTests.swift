import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-448 (FRD-002 FR-002-08, AC-002-07): an imported screenshot whose item the user deleted must not come back on
// relaunch because a second, unfinished file was born within 5 s after it. Written from the bug report: the hold on
// the unfinished file must not pull the persisted watermark back into the imported file's 5 s slack.
// Expected values are literals or test-owned dates: the production formulas are not repeated here.

private let slack: TimeInterval = 5
private let tolerance: TimeInterval = 0.01

@Suite("Task448 deleted import and an unfinished neighbour", .serialized)
struct Task448DeletedImportTests {
    @Test("AC-002-07: imported-then-deleted file stays gone after relaunch when a second unfinished file was born 3 s after it; the unfinished one is still found")
    func deletedImportStaysGoneBesideUnfinishedFile() async throws {
        // given: pickup running over an old watermark; file A (to be imported, its item then deleted) and file B,
        // born 3 s after A and unreadable, so it stays unfinished
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let bornA = rig.clock.now()
        let bornB = bornA.addingTimeInterval(3)
        let a = try rig.shot(in: rig.desktop, "Screenshot A \(UUID().uuidString).png", born: bornA)
        let b = try rig.shot(in: rig.desktop, "Screenshot B \(UUID().uuidString).png", born: bornB)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: b.path)

        // when: both arrive live; A is imported, B cannot be read
        rig.event(a)
        rig.event(b)
        #expect(await eventually { rig.ingest.names == [a.lastPathComponent] })
        #expect(await eventually { rig.notices.raised(.sspIo002) >= 1 })

        // then (state): the stored watermark is at least 5 s past A's birth, and still inside B's window
        let marked = try #require(rig.marks.value)
        #expect(marked >= bornA.addingTimeInterval(slack - tolerance), "watermark \(marked) is inside A's 5 s slack")
        #expect(marked < bornB.addingTimeInterval(slack), "watermark \(marked) is past B's window")

        // when: the user deleted A's item; B becomes readable; Flotsam relaunches with no scan in between
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: b.path)
        rig.relaunch()
        await rig.watcher.start()
        #expect(await eventually { rig.ingest.names.contains(b.lastPathComponent) })
        await letItSettle()

        // then: A was not imported a second time; B was imported once
        #expect(rig.ingest.names.filter { $0 == a.lastPathComponent }.count == 1, "deleted import resurfaced: \(rig.ingest.names)")
        #expect(rig.ingest.names.filter { $0 == b.lastPathComponent }.count == 1)
    }
}
