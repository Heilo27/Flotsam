import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// TASK-445 (FRD-002 FR-002-08, FRD-000 FR-000-11): the persisted watermark follows live imports and the 30 s tick, is
// held back behind unfinished files for 60 s, and every reconcile scan logs one `screenshot.scan` line.
// Expected values are literals or test-owned dates: the production formulas are not repeated here.

private let slack: TimeInterval = 5
private let tolerance: TimeInterval = 0.01

private func name(_ url: URL) -> String { url.lastPathComponent }

/// All `screenshot.scan` log lines, oldest first.
private func scanLines(_ rig: WatcherRig) -> [LogRecord] { rig.sink.records.filter { $0.headline == "screenshot.scan" } }

@Suite("Worf445 watermark follows live imports", .serialized)
struct Worf445LiveImportWatermarkTests {
    @Test("OC-2038/AC-002-07: a live import moves the persisted watermark 5 s past the file; a relaunch does not select it again")
    func liveImportDoesNotComeBackAfterRelaunch() async throws {
        // given: pickup running over an old watermark, then one screenshot arrives live and is imported
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let born = rig.clock.now()
        let file = try rig.shot(in: rig.desktop, born: born)
        rig.event(file)
        #expect(await eventually { rig.ingest.names == [name(file)] })
        // then (state): the stored watermark is at least 5 s past the file's birth
        #expect(await eventually { (rig.marks.value ?? .distantPast) >= born.addingTimeInterval(slack - tolerance) })

        // when: Flotsam is quit and relaunched with no scan in between (the item was deleted, so only the watermark remembers)
        await rig.relaunch()
        await rig.watcher.start()
        await letItSettle()

        // then: count delta 0, the same single name, the watermark never went back
        #expect(rig.ingest.names == [name(file)])
        #expect((rig.marks.value ?? .distantPast) >= born.addingTimeInterval(slack - tolerance))
    }

    @Test("OC-2038 boundary: a file born ahead of the clock still ends up 5 s inside the watermark")
    func watermarkNeverInsideSlackOfImportedFile() async throws {
        // given: a screenshot whose birth date is 2 s ahead of the watcher's clock
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let born = rig.clock.now().addingTimeInterval(2)
        let file = try rig.shot(in: rig.desktop, born: born)

        // when: it is imported live
        rig.event(file)
        #expect(await eventually { rig.ingest.names == [name(file)] })

        // then: the watermark is at least born + 5 s (now alone, ~born - 1.5 s, would let the slack select it again)
        #expect(await eventually { (rig.marks.value ?? .distantPast) >= born.addingTimeInterval(slack - tolerance) })
        await rig.relaunch()
        await rig.watcher.start()
        await letItSettle()
        #expect(rig.ingest.names == [name(file)])
    }

    @Test("FR-002-08: the 30 s tick moves the watermark to now while the folder is watched and nothing is unfinished")
    func tickMovesWatermarkToNow() async throws {
        // given: an idle watched folder, watermark 100 s back
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let beforeTick = rig.clock.now()

        // when: one 30 s tick runs
        await rig.tick()

        // then: the watermark is at least 30 s past where the clock stood before the tick
        #expect((rig.marks.value ?? .distantPast) >= beforeTick.addingTimeInterval(30 - tolerance))
    }
}

@Suite("Worf445 watermark holdback", .serialized)
struct Worf445HoldbackTests {
    /// Writes a hidden temp name born `age` seconds before the rig's clock; a screenshot macOS has not renamed yet.
    private func hiddenTemp(_ rig: WatcherRig, age: TimeInterval) throws -> (hidden: URL, born: Date) {
        let born = rig.clock.now().addingTimeInterval(-age)
        return (try rig.shot(in: rig.desktop, ".Screenshot hidden \(UUID().uuidString).png", born: born), born)
    }

    /// macOS finishing the save: the hidden temp is renamed to its final name (the birth date goes with it).
    private func renameIntoScreenshot(_ hidden: URL) throws -> URL {
        let final = hidden.deletingLastPathComponent().appendingPathComponent("Screenshot renamed \(UUID().uuidString).png")
        try FileManager.default.moveItem(at: hidden, to: final)
        return final
    }

    @Test("FR-002-08 caveat 1 (listed): a young hidden temp seen by a scan holds the watermark; renamed after a tick and a crash, relaunch imports it")
    func listedHiddenTempHoldsWatermark() async throws {
        // given: a hidden temp born 25 s ago is in the folder when pickup starts (watermark 100 s back)
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        let (hidden, born) = try hiddenTemp(rig, age: 25)
        await rig.watcher.start()

        // when: a 30 s tick runs (the temp is 55 s old: still inside the 60 s hold), then macOS renames it, then a crash
        await rig.tick()
        let heldAt = try #require(rig.marks.value)
        let final = try renameIntoScreenshot(hidden)
        await rig.relaunch()
        await rig.watcher.start()

        // then: the watermark stayed at or before the temp's birth, and the relaunch imported the renamed file once
        #expect(heldAt <= born.addingTimeInterval(tolerance), "watermark passed a hidden temp that may still be renamed")
        #expect(await eventually { rig.ingest.names == [name(final)] })
        await letItSettle()
        #expect(rig.ingest.names == [name(final)])
    }

    @Test("FR-002-08 caveat 1 (event): a hidden temp first seen through a file event holds the watermark across a tick")
    func eventHiddenTempHoldsWatermark() async throws {
        // given: pickup running and idle; then a hidden temp appears (its creation event arrives), born 1 s after start
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let startedAt = try #require(rig.marks.value)
        let born = startedAt.addingTimeInterval(1)
        let hidden = try rig.shot(in: rig.desktop, ".Screenshot event \(UUID().uuidString).png", born: born)
        rig.event(hidden)
        await letItSettle()

        // when: a tick runs, the temp is renamed, Flotsam crashes and relaunches
        await rig.tick()
        let heldAt = try #require(rig.marks.value)
        let final = try renameIntoScreenshot(hidden)
        await rig.relaunch()
        await rig.watcher.start()

        // then: the tick did not carry the watermark past the temp's birth, and the renamed file is imported once
        #expect(heldAt <= born.addingTimeInterval(tolerance), "tick moved the watermark past an unrenamed hidden temp")
        #expect(await eventually { rig.ingest.names == [name(final)] })
        await letItSettle()
        #expect(rig.ingest.names == [name(final)])
    }

    @Test("FR-002-08 boundary: a hidden temp older than 60 s no longer holds the watermark (65 s released, 55 s held)")
    func holdEndsAfterSixtySeconds() async throws {
        // given: two rigs, a hidden temp aged 35 s (65 s at the tick) and one aged 25 s (55 s at the tick)
        for (age, expectHeld) in [(35.0, false), (25.0, true)] {
            let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
            defer { rig.cleanUp() }
            let (hidden, born) = try hiddenTemp(rig, age: age)
            await rig.watcher.start()
            let beforeTick = rig.clock.now()

            // when: one tick, then the temp is renamed and Flotsam relaunches
            await rig.tick()
            let marked = try #require(rig.marks.value)
            _ = try renameIntoScreenshot(hidden)
            await rig.relaunch()
            await rig.watcher.start()
            await letItSettle()

            // then: held -> watermark at the temp's birth and the file is imported; released -> past the tick and not
            if expectHeld {
                #expect(marked <= born.addingTimeInterval(tolerance), "age \(age): held")
                #expect(rig.ingest.candidates.count == 1, "age \(age): held temp imported after rename")
            } else {
                #expect(marked >= beforeTick.addingTimeInterval(30 - tolerance), "age \(age): released")
                #expect(rig.ingest.candidates.isEmpty, "age \(age): released temp is outside the window")
            }
        }
    }

    @Test("FR-002-08: an unreadable (unstable) live file holds the watermark inside its 60 s, and releases after")
    func unstableFileHoldsThenReleases() async throws {
        // given: an unreadable screenshot born 5 s ago, found by the start scan (it fails the stability check)
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        let born = rig.clock.now().addingTimeInterval(-5)
        let stuck = try rig.shot(in: rig.desktop, "Screenshot stuck.png", born: born)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: stuck.path)
        await rig.watcher.start()
        #expect(await eventually { rig.notices.raised(.sspIo002) >= 1 })

        // when: one tick (the file is about 40 s old)
        await rig.tick()
        // (the tick's retry runs in a spawned task: wait for its failed try so the old launch is idle before the file opens)
        #expect(await eventually { rig.notices.raised(.sspIo002) >= 2 })

        // then: held at its birth; so that once it can be read, a relaunch still finds it
        #expect(try #require(rig.marks.value) <= born.addingTimeInterval(tolerance))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stuck.path)
        await rig.relaunch()
        await rig.watcher.start()
        let imported = await eventually { rig.ingest.names == [name(stuck)] }
        #expect(imported, "names \(rig.ingest.names) marks \(String(describing: rig.marks.value)) born \(born) notices \(rig.notices.entries)")

        // when: the same kind of file stays unreadable past 60 s of ticks
        let rig2 = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig2.cleanUp() }
        let born2 = rig2.clock.now().addingTimeInterval(-5)
        let stuck2 = try rig2.shot(in: rig2.desktop, "Screenshot stuck2.png", born: born2)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: stuck2.path)
        await rig2.watcher.start()
        await rig2.tick()
        await rig2.tick()
        await rig2.tick()

        // then: released, the watermark is past the file
        #expect(try #require(rig2.marks.value) >= born2.addingTimeInterval(60))
    }
}

@Suite("Worf445 failed import and the hold window (builder caveat 2)", .serialized)
struct Worf445FailedImportTests {
    @Test("FR-002-08 caveat 2: a storage-failed live import is retried by scans for 60 s, then the watermark passes it; an unstable one keeps its retry budget")
    func failedImportRetryWindow() async throws {
        // given: a screenshot whose ingest fails with a storage error, imported live (count 1)
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let file = try rig.shot(in: rig.desktop, "Screenshot failing.png", born: rig.clock.now())
        rig.ingest.fail(name(file), with: FlotsamError(.stoDb001, "scripted failure"))
        rig.event(file)
        #expect(await eventually { rig.ingest.candidates.count == 1 })

        // when/then: a wake scan inside the 60 s retries it (count 2); after one tick still inside (count 3)
        await rig.watcher.didWake()
        #expect(await eventually { rig.ingest.candidates.count == 2 })
        await rig.tick()
        await rig.watcher.didWake()
        #expect(await eventually { rig.ingest.candidates.count == 3 })

        // when/then: after a second tick the file is more than 60 s old and the watermark has passed it: no further try
        await rig.tick()
        await rig.watcher.didWake()
        await letItSettle()
        #expect(rig.ingest.candidates.count == 3, "a failed import older than 60 s is not retried (FR-002-08 hold window)")
    }
}

@Suite("Worf445 reconcile scan log (OC-2041, FR-000-11)", .serialized)
struct Worf445ScanLogTests {
    @Test("OC-2041: each scan writes one screenshot.scan line carrying succeeded and how many files it queued, and no file name")
    func scanLineCarriesOutcomeAndCount() async throws {
        // given: a watermark 100 s back and two qualifying screenshots born 10 s ago, found by the start scan
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        let born = rig.clock.now().addingTimeInterval(-10)
        let first = try rig.shot(in: rig.desktop, "Screenshot LOGMARK-one.png", born: born)
        let second = try rig.shot(in: rig.desktop, "Screenshot LOGMARK-two.png", born: born)

        // when: pickup starts
        await rig.watcher.start()
        #expect(await eventually { rig.ingest.candidates.count == 2 })

        // then: exactly one scan line: succeeded, count 2, never a name
        let lines = scanLines(rig)
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.publicContext.contains("outcome=succeeded"), "context: \(line.publicContext)")
        #expect(line.publicContext.contains("count=2"), "context: \(line.publicContext)")
        let everything = lines.map { $0.headline + $0.publicContext + $0.privateContext + ($0.message ?? "") }.joined()
        #expect(!everything.contains("LOGMARK") && !everything.contains(name(first)) && !everything.contains(name(second)))

        // when: a second scan finds nothing new
        await rig.watcher.didBecomeActive()
        await letItSettle()

        // then: one more line, count 0 (the files are already seen)
        let after = scanLines(rig)
        #expect(after.count == 2)
        #expect(after.last?.publicContext.contains("count=0") == true, "context: \(after.last?.publicContext ?? "")")
    }

    @Test("OC-2041 negative: a scan whose listing fails logs outcome failed with count 0, not succeeded")
    func failedListingLogsFailed() async throws {
        // given: pickup running, then the folder becomes unlistable
        let rig = try WatcherRig(watermark: Date().addingTimeInterval(-100))
        defer { rig.cleanUp() }
        await rig.watcher.start()
        let before = scanLines(rig).count
        rig.fileSystem.hide(rig.desktop)

        // when: a wake scan runs against the unlistable folder
        await rig.watcher.didWake()
        await letItSettle()

        // then: the new line says failed with 0 files
        let added = Array(scanLines(rig).dropFirst(before))
        #expect(added.count == 1)
        #expect(added.first?.publicContext.contains("outcome=failed") == true, "context: \(added.first?.publicContext ?? "")")
        #expect(added.first?.publicContext.contains("count=0") == true)
        #expect(added.first?.publicContext.contains("outcome=succeeded") == false)
    }
}
