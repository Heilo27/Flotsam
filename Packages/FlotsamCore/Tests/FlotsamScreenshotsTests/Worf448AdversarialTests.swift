import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// WORF-448 (FRD-002 FR-002-08, AC-002-07): adversarial cases around the watermark hold and the imported-file slack.
// Expected values are literals or test-owned dates; no production formula is repeated.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

@Suite("Worf448 heldBack boundaries")
struct Worf448HeldBackTests {
    /// OC-448-W1. given an unfinished file born exactly when the imported file was, when the watermark is held, then the
    /// hold wins: the watermark stays at that birth, so the unfinished file is still inside the next scan's window.
    @Test("OC-448-W1 an unfinished file born at the same instant as the import keeps the hold")
    func sameInstantHoldWins() {
        let held = ScreenshotSelection.heldBack(at(20), now: at(20), births: [at(10)], importedBirth: at(10))
        #expect(held == at(10))
    }

    /// OC-448-W2. given an unfinished file born before the imported one, then the hold wins.
    @Test("OC-448-W2 an unfinished file born before the import keeps the hold")
    func earlierUnfinishedHoldWins() {
        let held = ScreenshotSelection.heldBack(at(20), now: at(20), births: [at(8)], importedBirth: at(10))
        #expect(held == at(8))
    }

    /// OC-448-W3. given an unfinished file born 1 ms after the import, then the watermark moves to 5 s past the import
    /// (so the import is out of the window) and the unfinished file (born later) is still inside it.
    @Test("OC-448-W3 an unfinished file born just after the import yields to the import's slack")
    func justAfterYields() {
        let held = ScreenshotSelection.heldBack(at(20), now: at(20), births: [at(10.001)], importedBirth: at(10))
        #expect(held == at(15))
    }

    /// OC-448-W4. boundary: unfinished born 4.999 s / exactly 5 s / 5.001 s after the import (all while held).
    @Test("OC-448-W4 the lift never passes the unfinished file's own slack")
    func liftBounded() {
        // 4.999 s later: watermark 15 is still below its own 5 s slack edge (14.999 + 5 = 19.999): lifted to 15
        #expect(ScreenshotSelection.heldBack(at(20), now: at(20), births: [at(14.999)], importedBirth: at(10)) == at(15))
        // exactly at the import's slack: the held watermark is already at that edge; nothing to lift
        #expect(ScreenshotSelection.heldBack(at(20), now: at(20), births: [at(15)], importedBirth: at(10)) == at(15))
        // later than that: the hold already clears the import; it must not be raised past the file
        #expect(ScreenshotSelection.heldBack(at(20), now: at(20), births: [at(15.001)], importedBirth: at(10)) == at(15.001))
    }

    /// OC-448-W5. given several unfinished files, only the oldest decides.
    @Test("OC-448-W5 with several unfinished files the oldest decides")
    func oldestDecides() {
        let births = [at(13), at(11), at(30)]
        #expect(ScreenshotSelection.heldBack(at(20), now: at(20), births: births, importedBirth: at(10)) == at(15))
        // add one born before the import: the hold wins
        #expect(ScreenshotSelection.heldBack(at(20), now: at(20), births: births + [at(9)], importedBirth: at(10)) == at(9))
    }

    /// OC-448-W6. negative / empty: nothing unfinished means the proposal stands, whatever the import; no imported birth
    /// leaves the plain hold.
    @Test("OC-448-W6 no unfinished file, or no imported birth, leaves the old behaviour")
    func degenerate() {
        #expect(ScreenshotSelection.heldBack(at(20), now: at(20), births: [], importedBirth: at(10)) == at(20))
        #expect(ScreenshotSelection.heldBack(at(20), now: at(20), births: [at(11)]) == at(11))
        // a file past the hold window (60 s) holds nothing
        #expect(ScreenshotSelection.heldBack(at(100), now: at(100), births: [at(11)], importedBirth: at(10)) == at(100))
    }
}

@Suite("Worf448 watcher scenarios", .serialized)
struct Worf448WatcherTests {
    private func unreadable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }
    private func readable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    /// OC-448-W7. given B unfinished and born at the same instant as A (or 2 s before it), when A is imported and Flotsam
    /// relaunches, then B is still found: the hold won over A's slack.
    @Test("OC-448-W7 unfinished file born at or before the import is still found after relaunch", arguments: [0.0, -2.0])
    func unfinishedAtOrBeforeStillFound(offset: Double) async throws {
        // given
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let bornA = rig.clock.now()
        let a = try rig.shot(in: rig.desktop, "Screenshot A \(UUID().uuidString).png", born: bornA)
        let b = try rig.shot(in: rig.desktop, "Screenshot B \(UUID().uuidString).png", born: bornA.addingTimeInterval(offset))
        try unreadable(b)
        rig.event(b)
        #expect(await eventually { rig.notices.raised(.sspIo002) >= 1 })
        // when: A imports; Flotsam quits and relaunches with B readable
        rig.event(a)
        #expect(await eventually { rig.ingest.names == [a.lastPathComponent] })
        let marked = try #require(rig.marks.value)
        #expect(marked <= bornA.addingTimeInterval(0.01), "watermark \(marked) passed the unfinished file's birth")
        try readable(b)
        rig.relaunch()
        await rig.watcher.start()
        // then: B arrives exactly once; (A may be re-selected here: the documented hold-wins case, absorbed by dedupe)
        #expect(await eventually { rig.ingest.names.contains(b.lastPathComponent) })
        await letItSettle()
        #expect(rig.ingest.names.filter { $0 == b.lastPathComponent }.count == 1)
    }

    /// OC-448-W8. given B unfinished (born 3 s after A) and A, then A2 (born 1 s after A) imported live, with a relaunch
    /// between them while B is still unreadable, then after B settles and a second relaunch each of A, A2, B was
    /// ingested exactly once: no deleted import came back.
    @Test("OC-448-W8 several imports in a row with a relaunch between them do not resurface")
    func importsInARowAcrossRelaunch() async throws {
        // given
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let bornA = rig.clock.now()
        let a = try rig.shot(in: rig.desktop, "Screenshot A \(UUID().uuidString).png", born: bornA)
        let a2 = try rig.shot(in: rig.desktop, "Screenshot A2 \(UUID().uuidString).png", born: bornA.addingTimeInterval(1))
        let b = try rig.shot(in: rig.desktop, "Screenshot B \(UUID().uuidString).png", born: bornA.addingTimeInterval(3))
        try unreadable(b)
        rig.event(b)
        #expect(await eventually { rig.notices.raised(.sspIo002) >= 1 })

        // when: A imports; relaunch #1 with B still unreadable; then A2 imports on the new watcher
        rig.event(a)
        #expect(await eventually { rig.ingest.names == [a.lastPathComponent] })
        rig.relaunch()
        await rig.watcher.start()
        await letItSettle()
        rig.event(a2)
        #expect(await eventually { rig.ingest.names.contains(a2.lastPathComponent) })
        let marked = try #require(rig.marks.value)
        #expect(marked >= bornA.addingTimeInterval(6 - 0.01), "watermark \(marked) inside A2's slack")
        #expect(marked < bornA.addingTimeInterval(3 + 5), "watermark \(marked) past B's window")

        // when: B settles; relaunch #2
        try readable(b)
        rig.relaunch()
        await rig.watcher.start()
        #expect(await eventually { rig.ingest.names.contains(b.lastPathComponent) })
        await letItSettle()

        // then: three distinct files, each ingested once, in total
        let names = rig.ingest.names
        #expect(names.count == 3, "\(names)")
        #expect(Set(names) == [a.lastPathComponent, a2.lastPathComponent, b.lastPathComponent])
    }
}
