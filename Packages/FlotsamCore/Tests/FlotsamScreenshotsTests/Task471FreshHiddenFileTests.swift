import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-471 (FRD-002 FR-002-08): what a fresh hidden file in the watched folder does to the watermark.
// Question from the ticket: does the hold delay imports, duplicate them, or neither?
// Expected values are literals or test-owned dates; no production formula is repeated.

private let tolerance: TimeInterval = 0.01

@Suite("Task471 fresh hidden file and the watermark hold", .serialized)
struct Task471FreshHiddenFileTests {
    /// A hidden file that is not a screenshot temporary (a Finder `.DS_Store`-style name): it will never be renamed.
    private func freshHidden(_ rig: WatcherRig) throws -> (url: URL, born: Date) {
        let born = rig.clock.now()
        let url = try rig.shot(in: rig.desktop, ".hidden-note \(UUID().uuidString).txt", born: born, attribute: nil)
        return (url, born)
    }

    @Test("a fresh hidden file does not delay a live import, and holds the persisted watermark back at its birth")
    func liveImportNotDelayedWatermarkHeld() async throws {
        // given: pickup running over an old watermark; a hidden file is born, then a screenshot 10 s later
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let (hidden, bornHidden) = try freshHidden(rig)
        rig.event(hidden)
        let shot = try rig.shot(in: rig.desktop, born: bornHidden.addingTimeInterval(10))

        // when: the screenshot arrives live, with no clock movement
        rig.event(shot)

        // then: it is imported at once, exactly once
        #expect(await eventually { rig.ingest.names == [shot.lastPathComponent] })
        await letItSettle()
        #expect(rig.ingest.names == [shot.lastPathComponent])
        // and: the watermark did not pass the hidden file's birth
        let marked = try #require(rig.marks.value)
        #expect(marked <= bornHidden.addingTimeInterval(tolerance), "watermark \(marked) passed the fresh hidden file")
    }

    @Test("ticks inside the 60 s window keep the hold and import nothing twice; the first tick past it releases the hold")
    func tickKeepsThenReleasesHold() async throws {
        // given: a fresh hidden file, then a screenshot imported live
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let (hidden, bornHidden) = try freshHidden(rig)
        rig.event(hidden)
        let shot = try rig.shot(in: rig.desktop, born: bornHidden.addingTimeInterval(1))
        rig.event(shot)
        #expect(await eventually { rig.ingest.names == [shot.lastPathComponent] })

        // when: one tick (30 s after the hidden file's birth)
        await rig.tick()
        // then: still held, and the screenshot was not queued again
        #expect(try #require(rig.marks.value) <= bornHidden.addingTimeInterval(tolerance))
        await letItSettle()
        #expect(rig.ingest.names == [shot.lastPathComponent])

        // when: two more ticks (90 s after the hidden file's birth)
        await rig.tick()
        await rig.tick()
        // then: the hold has gone; the watermark is past the hidden file's window
        #expect(try #require(rig.marks.value) >= bornHidden.addingTimeInterval(60))
        #expect(rig.ingest.names == [shot.lastPathComponent])
    }

    @Test("a relaunch inside the window re-offers the import, and dedupe leaves one item; after the window it is not offered")
    func relaunchReoffersButDedupeHolds() async throws {
        // given: a fresh hidden file, then a screenshot imported live; the watermark is held at the hidden birth
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let (hidden, bornHidden) = try freshHidden(rig)
        rig.event(hidden)
        let shot = try rig.shot(in: rig.desktop, born: bornHidden.addingTimeInterval(10))
        rig.event(shot)
        #expect(await eventually { rig.ingest.names == [shot.lastPathComponent] })

        // when: Flotsam relaunches inside the window
        rig.relaunch()
        await rig.watcher.start()
        #expect(await eventually { rig.ingest.names.count == 2 })
        await letItSettle()

        // then: the same screenshot was offered to ingest again, and ingest saw one content key: one item (FR-002-10)
        #expect(rig.ingest.names == [shot.lastPathComponent, shot.lastPathComponent])
        #expect(Set(rig.ingest.candidates.map(\.contentKey)).count == 1)

        // when: the window passes (three ticks), then another relaunch
        await rig.tick()
        await rig.tick()
        await rig.tick()
        rig.relaunch()
        await rig.watcher.start()
        await letItSettle()
        // then: nothing is offered a third time
        #expect(rig.ingest.names.count == 2, "\(rig.ingest.names)")
    }
}
