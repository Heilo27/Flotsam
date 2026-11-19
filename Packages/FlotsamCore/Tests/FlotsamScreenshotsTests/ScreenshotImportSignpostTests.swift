import Foundation
import Testing
@testable import FlotsamBase
@testable import FlotsamScreenshots

// FRD-000 FR-000-12 / FRD-002 FR-002-14: every pickup is one `screenshot.import` signpost interval, whatever it came to.
// Two observers. What must be counted exactly (every pickup begins one interval and ends it once, ids distinct) is
// watched in-process through `Signposts.observe(scope:)` (IntervalTap): the unified-log signpost stream is lossy under
// host load, so counting through it failed one run in six at 200 busy processes (TASK-510). That the interval really
// reaches the system, in category perf and spanning the ingest, is checked through the real stream (SignpostProbe,
// shared with the Base tests by symlink) by OC-WORF457-01 alone, which needs one pair and no exact count.
//
// Other suites in this target run imports in the same process (some hold one open on purpose) and the stream cannot
// tell whose they are, so each test gives its importer its own signpost scope (TASK-510: `ScreenshotImporter.signpostScope`,
// `SignpostProbe(scope:)`) and judges only the intervals opened under it: its own imports, every one of which must have ended.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ScreenshotImportSignpostTests {
    func importer(scope: UInt32, ingest: IngestRecorder = IngestRecorder(), clock: any WallClock = ManualClock()) -> ScreenshotImporter {
        let fileSystem = LocalFileSystem()
        return ScreenshotImporter(
            fileSystem: fileSystem, stability: StabilityCheck(fileSystem: fileSystem, clock: clock), ingest: ingest,
            signpostScope: scope)
    }

    /// The probe's `screenshot.import` marks, split into begins and ends.
    func importMarks(_ probe: SignpostProbe) -> (begun: [SignpostProbe.Mark], ends: [SignpostProbe.Mark]) {
        let marks = probe.marks().filter { $0.event.name == "screenshot.import" }
        return (marks.filter { $0.event.type == "begin" }, marks.filter { $0.event.type == "end" })
    }

    /// An interval edge log for one scope, filled synchronously as the importer begins and ends its intervals, so once a
    /// `run` has returned its edges are all here.
    final class IntervalTap: @unchecked Sendable {
        let scope: UInt32
        private let lock = NSLock()
        private var edges: [ScopedSignpostEdge] = []

        init(scope: UInt32) {
            self.scope = scope
            Signposts.observe(scope: scope) { [weak self] edge in self?.record(edge) }
        }

        deinit { stop() }

        func stop() { Signposts.stopObserving(scope: scope) }

        private func record(_ edge: ScopedSignpostEdge) { lock.withLock { edges.append(edge) } }

        /// The serials of the `screenshot.import` intervals that began, and of those that ended (one entry per end).
        func importEdges() -> (begun: [UInt32], ends: [UInt32]) {
            let imports = lock.withLock { edges }.filter { $0.interval == .screenshotImport }
            return (imports.filter { $0.kind == .begin }.map(\.serial), imports.filter { $0.kind == .end }.map(\.serial))
        }
    }

    /// Waits (deadline-bound, no fixed pause) until at least `minimum` intervals have begun and every one has ended, then
    /// flushes the stream so an extra end emitted before this call would have been delivered, and returns the marks.
    func settledImportMarks(
        _ probe: SignpostProbe, atLeastBegun minimum: Int
    ) async throws -> (begun: [SignpostProbe.Mark], ends: [SignpostProbe.Mark]) {
        let settled = try await probe.wait { marks in
            let imports = marks.filter { $0.event.name == "screenshot.import" }
            let ended = Set(imports.filter { $0.event.type == "end" }.map(\.id))
            let begun = imports.filter { $0.event.type == "begin" }
            return begun.count >= minimum && begun.allSatisfy { ended.contains($0.id) }
        }
        // A wait that cannot succeed (the stream dropped an event) fails here, quickly and with its reason, instead of
        // running into the suite's time limit.
        #expect(settled, "the signpost stream never showed \(minimum) screenshot.import interval(s) begun and ended within the wait")
        try await probe.flush()
        return importMarks(probe)
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

        let scope = SignpostScopes.next()
        let tap = IntervalTap(scope: scope)
        defer { tap.stop() }
        let subject = importer(scope: scope)
        let attempts = [
            await subject.run(file(real), countsAsCopy: true),
            await subject.run(file(missing), countsAsCopy: true),
            await subject.run(file(link), countsAsCopy: true),
        ]
        guard case .imported = attempts[0], case .unstable = attempts[1], case .rejected = attempts[2] else {
            Issue.record("expected imported, unstable, rejected; got \(attempts)")
            return
        }
        let (begun, ends) = tap.importEdges()
        #expect(begun.count == 3, "begins \(begun.count)")
        #expect(begun.allSatisfy { ends.contains($0) }, "an interval began and never ended: \(begun.filter { !ends.contains($0) }.count)")
        #expect(ends.count == 3, "ends \(ends.count)")
    }
}
