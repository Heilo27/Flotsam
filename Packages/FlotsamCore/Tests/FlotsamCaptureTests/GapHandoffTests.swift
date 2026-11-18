import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

/// TASK-148 (FR-001-17): exactly one ingest per copy, however many ticks or retries observe it.
/// TASK-147 (FR-001-17): capture hands off from the main thread, never writes storage itself.
///
/// Seam note (reported on the tickets): `ClipboardCapture` takes the concrete `IngestActor`, there is no ingest
/// port to fake. One ingest is therefore counted at the observable edge of the real actor: it publishes exactly one
/// `.itemsChanged` per committed create or bump (FR-007-05), and it writes `copyCount`. Both are asserted.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct GapHandoffTests {
    /// OC-148-01. given one copy, when the timer ticks for 1.4 s (at least two real ticks) and five more manual ticks
    /// run with no new change, then exactly one ingest happened: one `.itemsChanged`, one row, copyCount 1. Turns red
    /// if a tick re-hands-off an already processed `changeCount` (lastProcessedChangeCount not recorded), which would
    /// bump copyCount and publish again on every tick.
    @Test("OC-148-01 one copy observed by many ticks is ingested exactly once")
    func repeatedTicksIngestOnce() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        rig.text("copied once")
        rig.capture.captureNow()
        #expect(await eventually { rig.itemsChangedCount.value == 1 })

        for _ in 1...5 { rig.capture.captureNow() }
        try await Task.sleep(for: .milliseconds(1400))  // the real 0.5 s timer ticks on the main run loop meanwhile
        await rig.settle()

        #expect(rig.itemsChangedCount.value == 1, "ingest ran more than once for one copy")
        let rows = try await rig.freshRows()
        #expect(rows.map(\.plainText) == ["copied once"])
        #expect(rows.map(\.copyCount) == [1])
    }

    /// OC-148-02. given three copies (a, b, then a again), then three ingests: three `.itemsChanged`, two rows, "a"
    /// copyCount 2 and "b" 1. Turns red if a copy is dropped (fewer events) or ingested twice (more events or a
    /// copyCount of 3).
    @Test("OC-148-02 each copy is one ingest: a, b, a again is three ingests and one bump")
    func eachCopyIsOneIngest() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        for (index, text) in ["a", "b", "a"].enumerated() {
            rig.text(text)
            rig.capture.captureNow()
            #expect(await eventually { rig.itemsChangedCount.value == index + 1 }, "copy \(index) not ingested exactly once")
        }
        await rig.settle()

        #expect(rig.itemsChangedCount.value == 3)
        let rows = try await rig.freshRows()
        #expect(rows.map(\.plainText) == ["a", "b"])
        #expect(rows.map(\.copyCount) == [2, 1])
    }

    /// OC-148-03. given a file-style copy caught mid-write (count bumped, board empty), when two retry ticks see the
    /// empty board, the bytes then arrive, and three more ticks run, then exactly one ingest happened. Turns red if
    /// the retry path hands the same change off more than once (once per retry tick) or loses it.
    @Test("OC-148-03 retry ticks for one mid-write copy end in exactly one ingest")
    func retryTicksIngestOnce() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()

        rig.pasteboard.beginCopy()
        rig.capture.captureNow()
        rig.capture.captureNow()
        #expect(await rig.itemCount() == 0, "nothing may be ingested while the board is empty")
        rig.pasteboard.finishCopy([GapRig.textType: Data("arrived late".utf8)])
        for _ in 1...4 { rig.capture.captureNow() }
        #expect(await eventually { rig.itemsChangedCount.value == 1 })
        await rig.settle()

        #expect(rig.itemsChangedCount.value == 1)
        let rows = try await rig.freshRows()
        #expect(rows.map(\.plainText) == ["arrived late"])
        #expect(rows.map(\.copyCount) == [1])
    }

    /// OC-148-04. given a copy the gates reject (concealed), when ticks run, then zero ingests: no event, no row.
    /// Turns red if a gated copy is handed to ingest.
    @Test("OC-148-04 a gated copy is never handed to ingest")
    func gatedCopyIsNeverIngested() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        rig.text("gated", markers: [PasteboardMarkers.concealed])
        for _ in 1...3 { rig.capture.captureNow() }
        try await Task.sleep(for: .milliseconds(300))
        await rig.settle()

        #expect(rig.itemsChangedCount.value == 0)
        #expect(try await rig.freshRows().isEmpty)
    }

    // MARK: TASK-147

    /// OC-147-01. given the main thread is held busy (a synchronous spin that never yields to the run loop or the
    /// main actor), when a copy is handed off, then the item still reaches the database while main is blocked.
    /// Turns red if the consumer that hashes and ingests runs on the main actor (`Task.detached` changed to a
    /// main-actor Task): it could not start until main yielded, so the row never appears during the spin.
    @Test("OC-147-01 the item is ingested while the main thread is blocked")
    func ingestHappensOffTheMainThread() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        rig.text("off main")
        rig.capture.captureNow()  // yields the payload; the consumer must run elsewhere

        // when: block this (main) thread, polling the file with a synchronous read, for up to 5 s
        let pool = rig.database.pool
        let deadline = Date().addingTimeInterval(5)
        var seen = 0
        while Date() < deadline, seen == 0 {
            seen = Self.blockingItemCount(pool)
            usleep(5_000)
        }

        // then
        #expect(Self.onMainThread(), "control: the spin ran on the main thread")
        #expect(seen == 1, "the copy was not ingested while the main thread was blocked")
        await rig.settle()
    }

    /// Synchronous reads, so the calling (main) thread really blocks instead of suspending at an await.
    nonisolated private static func blockingItemCount(_ pool: DatabasePool) -> Int {
        (try? pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") }) ?? 0
    }

    nonisolated private static func onMainThread() -> Bool { Thread.isMainThread }

    /// OC-147-02. given every Swift file of the Capture module, when scanned, then none imports GRDB or names a
    /// database, pool, SQL statement or write call: its only route to storage is the ingest actor. Turns red if
    /// capture gains a direct storage write. Controls: the scan reads real files, finds the ingest call it must have,
    /// and flags a synthetic offender.
    @Test("OC-147-02 Capture sources contain no direct storage access, only the ingest actor")
    func captureNeverWritesStorageDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FlotsamCapture")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
        let banned = ["import GRDB", "DatabasePool", "DatabaseQueue", "FlotsamDatabase", ".pool", "INSERT INTO", "UPDATE item",
                      "DELETE FROM", "SELECT ", ".write {", "db.execute"]
        func offenders(in text: String) -> [String] { banned.filter { text.contains($0) } }

        // control: real files, the real ingest call, and the scanner can flag an offender
        #expect(files.count >= 3, "scan found \(files.count) files under \(sources.path)")
        let all = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        #expect(all.contains("await ingest.ingest(candidate)"))
        #expect(offenders(in: "import GRDB\ntry pool.write { }") == ["import GRDB", ".write {"])

        // then
        for (file, text) in zip(files, try files.map { try String(contentsOf: $0, encoding: .utf8) }) {
            #expect(offenders(in: text).isEmpty, "\(file.lastPathComponent) touches storage directly: \(offenders(in: text))")
        }
    }
}
