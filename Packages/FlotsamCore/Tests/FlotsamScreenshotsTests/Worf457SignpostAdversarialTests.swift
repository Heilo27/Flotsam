import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// WORF-457 (blind QA of TASK-457 item 3 / TASK-229, FRD-000 FR-000-12, FRD-002 FR-002-14): adversarial cover for the
// `screenshot.import` interval that ScreenshotImportSignpostTests does not pin. That suite proves "begun and ended on
// three early outcomes"; it cannot see an interval that closes too EARLY (it only checks that an end exists), an end
// shared between overlapping pickups, or the late outcomes (ingest failure, cancellation).
//
// Declared as an EXTENSION of that suite on purpose: a Swift Testing suite's tests run in parallel with other suites',
// and the hold tests here keep an interval open for seconds. As a separate suite they landed inside ScreenshotImportSignpostTests'
// time window and made it red ("an interval began and never ended"). In the same `.serialized` suite they cannot overlap it.
// Same discipline as there (TASK-510): each test gives its importer its own signpost scope and judges only its own intervals.
extension ScreenshotImportSignpostTests {
    private func advFile(_ url: URL) -> ScreenshotFile {
        ScreenshotFile(url: url, folder: url.deletingLastPathComponent(), createdAt: Date(), byteSize: 4)
    }

    private func advOpenIDs(_ probe: SignpostProbe) -> Set<Int> {
        let (begun, ends) = importMarks(probe)
        return Set(begun.map(\.id)).subtracting(Set(ends.map(\.id)))
    }

    /// OC-WORF457-01. given a pickup whose ingest is held, then its interval is OPEN while the ingest runs (it covers
    /// "the stability check to the ingest result", FR-002-14) and closes once the ingest returns. Red if the end is
    /// moved ahead of the ingest (for example `span.end()` right after the begin, or after only the stability wait).
    @Test("OC-WORF457-01 the interval stays open across the ingest and closes when the ingest returns")
    func intervalSpansTheIngest() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.file("shots/Screenshot held.png")
        let ingest = IngestRecorder()
        ingest.holdIngest(named: "Screenshot held.png")
        let scope = SignpostScopes.next()
        let probe = SignpostProbe(scope: scope)
        do {
            try await probe.start()
            let subject = importer(scope: scope, ingest: ingest)
            let job = Task { await subject.run(advFile(real), countsAsCopy: true) }
            // Wait until the pickup is inside the ingest, then until the stream has delivered what it has begun.
            #expect(await eventually(timeout: .seconds(20)) { ingest.heldIngests == 1 }, "the pickup never reached the ingest")
            let begunSeen = try await probe.wait { !$0.filter { $0.event.name == "screenshot.import" && $0.event.type == "begin" }.isEmpty }
            #expect(begunSeen, "the signpost stream never delivered the begin of the held pickup's interval")
            try await probe.flush()
            let openWhileHeld = advOpenIDs(probe)
            ingest.releaseIngest(named: "Screenshot held.png")
            let attempt = await job.value
            _ = try await settledImportMarks(probe, atLeastBegun: 1)
            let openAfter = advOpenIDs(probe)
            await probe.stop()
            guard case .imported = attempt else { Issue.record("expected imported, got \(attempt)"); return }
            #expect(!openWhileHeld.isEmpty, "no interval was open while the ingest was held")
            #expect(!openWhileHeld.subtracting(openAfter).isEmpty, "the interval that was open during the ingest never closed after it")
            let (begun, ends) = importMarks(probe)
            #expect(Set((begun + ends).map(\.event.category)) == ["perf"], "the real signpost is not in category perf")
        } catch {
            ingest.releaseIngest(named: "Screenshot held.png")
            await probe.stop()
            throw error
        }
    }

    /// OC-WORF457-02. given two overlapping pickups (both held in the ingest), then each has its own interval id and
    /// each id ends exactly once. Red if the two share one signpost id (a pickup would close its neighbour's interval)
    /// or if a pickup ends its interval twice.
    @Test("OC-WORF457-02 overlapping pickups get distinct interval ids and each id ends exactly once")
    func overlappingPickupsKeepSeparateIntervals() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let first = try temp.file("shots/Screenshot one.png", bytes: Data([0x89, 0x50, 0x4E, 0x47, 1]))
        let second = try temp.file("shots/Screenshot two.png", bytes: Data([0x89, 0x50, 0x4E, 0x47, 2]))
        let ingest = IngestRecorder()
        ingest.holdIngests()
        let scope = SignpostScopes.next()
        let tap = IntervalTap(scope: scope)
        defer {
            ingest.releaseIngests()
            tap.stop()
        }
        let subject = importer(scope: scope, ingest: ingest)
        let jobs = [Task { await subject.run(advFile(first), countsAsCopy: true) }, Task { await subject.run(advFile(second), countsAsCopy: true) }]
        #expect(await eventually(timeout: .seconds(20)) { ingest.heldIngests == 2 }, "the two pickups never both reached the ingest")
        ingest.releaseIngests()
        for job in jobs { _ = await job.value }
        let (begun, ends) = tap.importEdges()
        #expect(begun.count == 2, "begins \(begun.count)")
        #expect(Set(begun).count == begun.count, "two intervals began with the same id: \(begun)")
        for id in begun {
            #expect(ends.filter { $0 == id }.count == 1, "interval \(id) ended \(ends.filter { $0 == id }.count) times")
        }
    }

    /// OC-WORF457-03. given the outcomes the S2 suite does not drive, an ingest that fails (STO-DB-001), an ingest that
    /// rejects (SSP-LIM-001) and a pickup cancelled while it waits, then each opens and closes an interval. Red if the
    /// end is only on a success path, or only on the paths before the ingest.
    ///
    /// The cancelled pickup waits on a clock that parks every sleep until the task is cancelled, and the test cancels it
    /// only once it is parked, so it is cancelled while waiting on every run (cancelling straight after `Task {}` raced the
    /// pickup: on a fast scheduler it had already finished and came back imported).
    @Test("OC-WORF457-03 a failed, a rejected and a cancelled pickup each close their interval")
    func lateOutcomesCloseTheirInterval() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let failing = try temp.file("shots/Screenshot fails.png", bytes: Data([0x89, 0x50, 0x4E, 0x47, 3]))
        let tooBig = try temp.file("shots/Screenshot big.png", bytes: Data([0x89, 0x50, 0x4E, 0x47, 4]))
        let cancelled = try temp.file("shots/Screenshot cancelled.png", bytes: Data([0x89, 0x50, 0x4E, 0x47, 5]))
        let ingest = IngestRecorder()
        ingest.fail("Screenshot fails.png", with: FlotsamError(.stoDb001, "scripted"))
        ingest.fail("Screenshot big.png", with: FlotsamError(.sspLim001, "scripted"))
        let scope = SignpostScopes.next()
        let tap = IntervalTap(scope: scope)
        defer { tap.stop() }
        let parked = ParkingClock()
        let subject = importer(scope: scope, ingest: ingest)
        let failedAttempt = await subject.run(advFile(failing), countsAsCopy: true)
        let rejectedAttempt = await subject.run(advFile(tooBig), countsAsCopy: true)
        let waiting = importer(scope: scope, ingest: ingest, clock: parked)
        let task = Task { await waiting.run(advFile(cancelled), countsAsCopy: true) }
        #expect(await eventually(timeout: .seconds(20)) { parked.parkedCount == 1 }, "the pickup never reached its wait")
        task.cancel()
        let cancelledAttempt = await task.value
        guard case .failed = failedAttempt, case .rejected = rejectedAttempt, case .unstable = cancelledAttempt else {
            Issue.record("expected failed, rejected, unstable; got \(failedAttempt) \(rejectedAttempt) \(cancelledAttempt)")
            return
        }
        let (begun, ends) = tap.importEdges()
        #expect(begun.count == 3, "begins \(begun.count)")
        #expect(begun.allSatisfy { ends.contains($0) }, "an interval began and never ended: \(begun.filter { !ends.contains($0) }.count)")
        #expect(ends.count == 3, "ends \(ends.count)")
    }
}

/// A clock whose every sleep parks until the sleeping task is cancelled, so a test can cancel a pickup exactly while it
/// is waiting. `now()` is fixed.
final class ParkingClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var parked = 0
    private let at = Date()
    var parkedCount: Int { lock.withLock { parked } }
    func now() -> Date { at }
    func sleep(for duration: Duration) async {
        lock.withLock { parked += 1 }
        // Returns on cancellation (the WallClock contract); the loop ends the first time the task is cancelled.
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
