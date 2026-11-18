import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// FRD-000 FR-000-12 / FRD-002 FR-002-14: every pickup is one `screenshot.import` signpost interval, whatever it came to.
// Observed through the real unified-log signpost stream (SignpostProbe, shared with the Base tests by symlink).
//
// Other suites in this target run imports in the same process (some hold one open on purpose) and the stream cannot
// tell whose they are, so only the intervals that BEGIN inside this test's own time window are judged: at least its three
// imports, and every one of them must have ended.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ScreenshotImportSignpostTests {
    private func importer() -> ScreenshotImporter {
        let fileSystem = LocalFileSystem()
        return ScreenshotImporter(
            fileSystem: fileSystem, stability: StabilityCheck(fileSystem: fileSystem, clock: ManualClock()), ingest: IngestRecorder())
    }

    private func file(_ url: URL) -> ScreenshotFile {
        ScreenshotFile(url: url, folder: url.deletingLastPathComponent(), createdAt: Date(), byteSize: 4)
    }

    /// given one imported file, one that vanished before the stability check (SSP-IO-002) and one symlink refused
    /// (SSP-VAL-001), then each opens and closes a `screenshot.import` interval in category `perf`. Red if the interval
    /// is not begun, or not ended on an early return.
    @Test("each pickup, imported or refused or unstable, is one screenshot.import interval")
    func importIntervalOnEveryOutcome() async throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let real = try temp.file("shots/Screenshot real.png")
        let missing = temp.root.appendingPathComponent("shots/Screenshot gone.png")
        let link = temp.root.appendingPathComponent("shots/Screenshot link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let probe = SignpostProbe()
        do {
            try await probe.start()
            let subject = importer()
            let windowStart = Date().addingTimeInterval(-0.05)
            let attempts = [
                await subject.run(file(real), countsAsCopy: true),
                await subject.run(file(missing), countsAsCopy: true),
                await subject.run(file(link), countsAsCopy: true),
            ]
            let windowEnd = Date().addingTimeInterval(0.05)
            _ = try await probe.collect(atLeast: 6)
            let marks = probe.marks().filter { $0.event.name == "screenshot.import" }
            await probe.stop()
            guard case .imported = attempts[0], case .unstable = attempts[1], case .rejected = attempts[2] else {
                Issue.record("expected imported, unstable, rejected; got \(attempts)")
                return
            }
            let begun = marks.filter { $0.event.type == "begin" && $0.at >= windowStart && $0.at <= windowEnd }
            let endedIDs = Set(marks.filter { $0.event.type == "end" }.map(\.id))
            #expect(begun.count >= 3, "begins in window \(begun.count)")
            #expect(begun.allSatisfy { endedIDs.contains($0.id) }, "an interval began and never ended: \(begun.filter { !endedIDs.contains($0.id) }.count)")
            #expect(Set(marks.map(\.event.category)) == ["perf"])
        } catch {
            await probe.stop()
            throw error
        }
    }
}
