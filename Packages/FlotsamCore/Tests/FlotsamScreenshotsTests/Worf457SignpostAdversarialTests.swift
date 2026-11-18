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
// Same window discipline as there: only intervals that BEGIN in a test's own time window are judged.
extension ScreenshotImportSignpostTests {
    private func advImporter(_ ingest: IngestRecorder) -> ScreenshotImporter {
        let fileSystem = LocalFileSystem()
        return ScreenshotImporter(fileSystem: fileSystem, stability: StabilityCheck(fileSystem: fileSystem, clock: ManualClock()), ingest: ingest)
    }

    private func advFile(_ url: URL) -> ScreenshotFile {
        ScreenshotFile(url: url, folder: url.deletingLastPathComponent(), createdAt: Date(), byteSize: 4)
    }

    private func advMarks(_ probe: SignpostProbe, from windowStart: Date) -> (begun: [SignpostProbe.Mark], ends: [SignpostProbe.Mark]) {
        let marks = probe.marks().filter { $0.event.name == "screenshot.import" }
        return (marks.filter { $0.event.type == "begin" && $0.at >= windowStart }, marks.filter { $0.event.type == "end" })
    }

    private func advOpenIDs(_ probe: SignpostProbe, from windowStart: Date) -> Set<Int> {
        let (begun, ends) = advMarks(probe, from: windowStart)
        let ended = Set(ends.map(\.id))
        return Set(begun.map(\.id)).subtracting(ended)
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
        let probe = SignpostProbe()
        do {
            try await probe.start()
            let subject = advImporter(ingest)
            let windowStart = Date().addingTimeInterval(-0.05)
            let job = Task { await subject.run(advFile(real), countsAsCopy: true) }
            // Wait until the pickup is inside the ingest, then let the stream catch up with what it has begun.
            for _ in 0..<200 where ingest.heldIngests < 1 { try await Task.sleep(for: .milliseconds(25)) }
            #expect(ingest.heldIngests == 1)
            for _ in 0..<100 where self.advMarks(probe, from: windowStart).begun.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            try await Task.sleep(for: .seconds(1.5))
            let openWhileHeld = advOpenIDs(probe, from: windowStart)
            ingest.releaseIngest(named: "Screenshot held.png")
            let attempt = await job.value
            for _ in 0..<100 where !openWhileHeld.isDisjoint(with: self.advOpenIDs(probe, from: windowStart)) { try await Task.sleep(for: .milliseconds(100)) }
            try await Task.sleep(for: .seconds(1.5))
            let openAfter = advOpenIDs(probe, from: windowStart)
            await probe.stop()
            guard case .imported = attempt else { Issue.record("expected imported, got \(attempt)"); return }
            #expect(!openWhileHeld.isEmpty, "no interval was open while the ingest was held")
            #expect(!openWhileHeld.subtracting(openAfter).isEmpty, "the interval that was open during the ingest never closed after it")
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
        let probe = SignpostProbe()
        do {
            try await probe.start()
            let subject = advImporter(ingest)
            let windowStart = Date().addingTimeInterval(-0.05)
            let jobs = [Task { await subject.run(advFile(first), countsAsCopy: true) }, Task { await subject.run(advFile(second), countsAsCopy: true) }]
            for _ in 0..<200 where ingest.heldIngests < 2 { try await Task.sleep(for: .milliseconds(25)) }
            #expect(ingest.heldIngests == 2)
            ingest.releaseIngests()
            for job in jobs { _ = await job.value }
            _ = try await probe.collect(atLeast: 4)
            let (begun, ends) = advMarks(probe, from: windowStart)
            await probe.stop()
            let begunIDs = begun.map(\.id)
            #expect(begunIDs.count >= 2, "begins in window \(begunIDs.count)")
            #expect(Set(begunIDs).count == begunIDs.count, "two intervals began with the same signpost id: \(begunIDs)")
            for id in begunIDs {
                #expect(ends.filter { $0.id == id }.count == 1, "interval \(id) ended \(ends.filter { $0.id == id }.count) times")
            }
        } catch {
            ingest.releaseIngests()
            await probe.stop()
            throw error
        }
    }

    /// OC-WORF457-03. given the outcomes the S2 suite does not drive, an ingest that fails (STO-DB-001), an ingest that
    /// rejects (SSP-LIM-001) and a pickup cancelled while it waits, then each opens and closes an interval. Red if the
    /// end is only on a success path, or only on the paths before the ingest.
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
        let probe = SignpostProbe()
        do {
            try await probe.start()
            let subject = advImporter(ingest)
            let windowStart = Date().addingTimeInterval(-0.05)
            let failedAttempt = await subject.run(advFile(failing), countsAsCopy: true)
            let rejectedAttempt = await subject.run(advFile(tooBig), countsAsCopy: true)
            let task = Task { await subject.run(advFile(cancelled), countsAsCopy: true) }
            task.cancel()
            let cancelledAttempt = await task.value
            _ = try await probe.collect(atLeast: 6)
            let (begun, ends) = advMarks(probe, from: windowStart)
            await probe.stop()
            guard case .failed = failedAttempt, case .rejected = rejectedAttempt, case .unstable = cancelledAttempt else {
                Issue.record("expected failed, rejected, unstable; got \(failedAttempt) \(rejectedAttempt) \(cancelledAttempt)")
                return
            }
            let endedIDs = Set(ends.map(\.id))
            #expect(begun.count >= 3, "begins in window \(begun.count)")
            #expect(begun.allSatisfy { endedIDs.contains($0.id) }, "an interval began and never ended: \(begun.filter { !endedIDs.contains($0.id) }.count)")
        } catch {
            await probe.stop()
            throw error
        }
    }
}
