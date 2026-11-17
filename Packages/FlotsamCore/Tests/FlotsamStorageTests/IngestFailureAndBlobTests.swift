import CryptoKit
import Foundation
import GRDB
import OSLog
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T gap batch, blob safety and failed writes (FR-007-04, FR-007-05). A database write failure is forced with a
// trigger that aborts the insert, installed and removed through the writer; results are read back through a separate
// connection and the files on disk. Expected values are literals.
//
// Layer note (OC-7031): the Notice that carries the CAP-IO-001 text, and the CAP-IO-001 log line, are raised by
// Capture, which has no code in this package yet. Storage hands back STO-DB-001; that is what is asserted here. The
// Notice and the CAP-IO-001 log are GAP-blocked on the Capture FRD.

@Suite struct IngestFailureAndBlobTests {
    private func exec(_ rig: Rig, _ sql: String) async throws {
        try await rig.store.database.pool.write { try $0.execute(sql: sql) }
    }

    private func failEveryRepresentationInsert(_ rig: Rig) async throws {
        try await exec(rig, "CREATE TRIGGER forced_failure BEFORE INSERT ON representation BEGIN SELECT RAISE(ABORT, 'forced'); END")
    }

    private func failEveryItemInsert(_ rig: Rig) async throws {
        try await exec(rig, "CREATE TRIGGER forced_failure BEFORE INSERT ON item BEGIN SELECT RAISE(ABORT, 'forced'); END")
    }

    private func clearFault(_ rig: Rig) async throws { try await exec(rig, "DROP TRIGGER forced_failure") }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func attributes(_ url: URL) throws -> (size: Int, modified: Date) {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return (a[.size] as! Int, a[.modificationDate] as! Date)
    }

    // MARK: OC-7022

    /// OC-7022. Given image item I with blob hash H, when it is pinned, tagged, noted, copied again (bump) and the quality
    /// preset changes, then I's blob still has hash H, the same size and the same modification time, and a second
    /// image with the same bytes under the new preset did not rewrite it either.
    @Test("OC-7022 pin, tag, note, bump and a quality change never touch a stored blob")
    func oc7022_blobIsNeverModifiedInPlace() async throws {
        // given a stored image, with a neighbour item before and after it
        let rig = try await Rig.make(quality: .balanced)
        defer { rig.cleanUp() }
        try await rig.store.insert([Spec(n: 1, text: "neighbour one"), Spec(n: 3, text: "neighbour three")])
        let png = TestImage.make(width: 96, height: 64, format: .png)
        let id = try await rig.create(rig.image("k-7022", png))
        let rep = try #require(try rig.reps(id).first)
        let url = rig.store.blobsDir.appendingPathComponent(rep.blobName)
        let hashBefore = try sha256(url)
        let before = try attributes(url)
        #expect(before.size == rep.byteSize.asInt)
        #expect(try rig.itemCount() == 3)
        try await Task.sleep(nanoseconds: 1_100_000_000)  // so an in-place rewrite would move the modification time

        // when the user pins it, tags it, adds a note, copies it again and changes the quality preset
        _ = try await rig.store.database.applyExemptionEdit(.setPinned(true), to: id).get()
        try await rig.store.database.pool.write { db in
            try db.execute(sql: "INSERT INTO tag (name, color, createdAt) VALUES ('work', 'red', 0)")
            try db.execute(sql: "INSERT INTO itemTag (itemId, tagId) VALUES (?, last_insert_rowid())", arguments: [id.uuidString])
            try db.execute(sql: "UPDATE item SET note = 'kept for the report' WHERE id = ?", arguments: [id.uuidString])
        }
        let again = try await rig.ingest.ingest(rig.image("k-7022", png)).get()
        rig.settings.set(.efficient, for: SettingKeys.storageImageQuality)
        let afterQuality = try await rig.ingest.ingest(rig.image("k-7022", png)).get()

        // then each copy was a bump of the same item, nothing was added, and the blob is byte-identical and untouched
        guard case .bumped(let first) = again.outcome, case .bumped(let second) = afterQuality.outcome else {
            Issue.record("expected both re-copies to bump")
            return
        }
        #expect(first == id && second == id)
        let row = try rig.row(id)
        #expect(row.copyCount == 3)
        #expect(row.pinned == 1)
        #expect(row.note == "kept for the report")
        #expect(try rig.itemCount() == 3)
        #expect(try rig.reps(id) == [rep])
        #expect(try sha256(url) == hashBefore)
        let after = try attributes(url)
        #expect(after.size == before.size)
        #expect(after.modified == before.modified)
        #expect(rig.blobFiles() == [rep.blobName])
    }

    // MARK: OC-7023

    /// OC-7023. Given three blobs renamed into blobs/ whose transactions never committed (the process died), when the
    /// store is reopened and reconcile runs after they are over 10 minutes old, then all three files are gone, no row
    /// references them, the healthy item's blob stays, and STO-IO-003 "Orphan blob removed" was logged at least three
    /// times (once per orphan).
    /// The orphan log line carries no context (no id, no blob name), so it cannot be matched to this test's uuids. The
    /// bound is therefore "at least 3 lines of that exact code and message since this test started": the only way to
    /// reach 3 is the reconcile in this test removing three orphans; if the code changes, no line matches at all.
    @Test("OC-7023 OC-7113 orphans left by a killed ingest are removed by reconcile and logged STO-IO-003")
    func oc7023_killedIngestOrphanIsReconciled() async throws {
        // given one stored image and three blobs written by ingests that died before their transactions
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let kept = try await rig.create(rig.image("k-7023-kept", TestImage.make(width: 40, height: 40, format: .png)))
        let keptBlob = try #require(try rig.reps(kept).first)
        let orphanNames = try (0..<3).map {
            try rig.store.database.blobs.write(Data("died-before-commit-\($0)".utf8), itemId: UUID(), ordinal: 0).get()
        }
        let orphanURLs = orphanNames.map { rig.store.blobsDir.appendingPathComponent($0) }
        #expect(orphanURLs.allSatisfy { rig.store.exists($0) }, "precondition")
        #expect(try rig.store.count("representation") == 1)
        let logged = ProcessLogProbe()

        // when 9 minutes pass, reconcile leaves them alone; when they are 11 minutes old, reconcile removes them
        rig.store.clock.advance(ms: 9 * 60_000)
        let early = try await rig.store.database.reconcile().get()
        #expect(early.orphanBlobsRemoved == 0)
        #expect(orphanURLs.allSatisfy { rig.store.exists($0) })
        rig.store.clock.advance(ms: 2 * 60_000)
        let late = try await rig.store.database.reconcile().get()

        // then the orphans are gone and nothing else is
        #expect(late.orphanBlobsRemoved == 3)
        #expect(orphanURLs.allSatisfy { !rig.store.exists($0) })
        #expect(rig.blobFiles() == [keptBlob.blobName])
        #expect(try rig.reps(kept) == [keptBlob])
        #expect(try rig.store.count("representation") == 1)
        #expect(try rig.store.count("item") == 1)
        let lines = await logged.waitForEntries(atLeast: 3, containing: ["STO-IO-003", "Orphan blob removed by reconcile"])
        #expect(lines.count >= 3, "orphan removals logged as STO-IO-003: saw \(lines.count)")
    }

    // MARK: OC-7025

    /// OC-7025. Given blob count B0 (one image stored beside it), when a database write failure is forced and another
    /// image is copied, then the copy fails with STO-DB-001, the blob count is still B0, the item count is unchanged
    /// and the existing image's blob is the same file.
    @Test("OC-7025 a failed write after the blob was written leaves no new blob and no new item")
    func oc7025_failedWriteLeavesNoBlob() async throws {
        // given an image already stored
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let existing = try await rig.create(rig.image("k-7025-a", TestImage.make(width: 48, height: 48, format: .png)))
        let existingRep = try #require(try rig.reps(existing).first)
        let blobsBefore = rig.blobFiles()
        #expect(blobsBefore == [existingRep.blobName])
        #expect(try rig.itemCount() == 1)
        try await failEveryRepresentationInsert(rig)

        // when a different image is copied
        let result = await rig.ingest.ingest(rig.image("k-7025-b", TestImage.make(width: 64, height: 40, format: .png)))

        // then it fails as a database error, nothing was left behind, and the stored image is intact
        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.code == .stoDb001)
        #expect(rig.blobFiles() == blobsBefore)
        #expect(try rig.itemCount() == 1)
        #expect(try rig.store.count("representation") == 1)
        #expect(try rig.reps(existing) == [existingRep])
        #expect(rig.store.names(in: rig.store.root.appendingPathComponent("tmp")).isEmpty)
    }

    /// Counts file writes once armed and says whether the current one is the Nth, from any thread.
    private final class WriteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var writes = 0
        func arm() { lock.withLock { armed = true } }
        var count: Int { lock.withLock { writes } }
        func isWrite(_ n: Int) -> Bool {
            lock.withLock {
                guard armed else { return false }
                writes += 1
                return writes == n
            }
        }
    }

    /// OC-7025. Given one rich-text item stored (blob set B0), when a three-representation copy is ingested and its second blob
    /// write fails, then the copy fails with STO-IO-001, the blob already written for it is removed so the blob files
    /// are exactly B0, the item and representation counts are unchanged and tmp/ is empty.
    @Test("OC-7025 a blob write failure part-way removes the blobs already written")
    func oc7025_secondBlobWriteFailureRemovesTheFirst() async throws {
        // given one image stored, then the file system armed to fail the second write
        let counter = WriteCounter()
        let store = try await Store.make(fileSystem: FaultyFileSystem(failWrite: { _ in counter.isWrite(2) }))
        defer { store.cleanUp() }
        let settings = SettingsStore(store: MemoryKV())
        let rig = Rig(
            store: store, settings: settings, ingest: IngestActor(database: store.database, settings: settings),
            fileSystem: CapacityFileSystem(capacity: nil))
        // (rich text, not an image: an image warms thumbnails unawaited, and those writes would race the counter)
        let existing = try await rig.create(rig.rich("k-7025-keep", plain: "kept", rtf: Data("kept-rtf".utf8)))
        let existingRep = try #require(try rig.reps(existing).first)
        let baseline = rig.blobFiles()
        #expect(baseline == [existingRep.blobName])
        #expect(try rig.itemCount() == 1)
        counter.arm()

        // when a copy with three representations is ingested
        let result = await rig.ingest.ingest(IngestCandidate(
            kind: .richText, contentKey: "k-7025-three", plainText: "three reps",
            representations: [
                PasteboardRepresentation(uti: "public.rtf", data: Data("rtf-bytes".utf8)),
                PasteboardRepresentation(uti: "public.html", data: Data("html-bytes".utf8)),
                PasteboardRepresentation(uti: "com.example.custom", data: Data("custom-bytes".utf8)),
            ],
            origin: .pasteboard, occurredAt: Date(timeIntervalSince1970: Double(store.clock.millis) / 1000)))

        // then it fails as a file error, stopped at the second write, and nothing it wrote is left behind
        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.code == .stoIo001)
        #expect(counter.count == 2, "the third write is never attempted")
        #expect(rig.blobFiles() == baseline)
        #expect(try rig.itemCount() == 1)
        #expect(try rig.store.count("representation") == 1)
        #expect(try rig.reps(existing) == [existingRep])
        #expect(rig.store.names(in: rig.store.root.appendingPathComponent("tmp")).isEmpty)
    }

    // MARK: OC-7031 (storage half)

    /// OC-7031, the part Storage owns. Given item count N=2 and blob count B0=1, when a write failure is forced and an
    /// image is copied, then exactly one error comes back and it is STO-DB-001 (the underlying code Capture wraps in
    /// CAP-IO-001), the counts are N and B0, and no second attempt wrote anything.
    @Test("OC-7031 storage half: a failed image copy returns one STO-DB-001 and leaves counts unchanged")
    func oc7031_storageHalf() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.store.insert(Spec(n: 1, text: "plain neighbour"))
        let stored = try await rig.create(rig.image("k-7031-a", TestImage.make(width: 32, height: 32, format: .png)))
        let blobsBefore = rig.blobFiles()
        #expect(blobsBefore.count == 1)
        #expect(try rig.itemCount() == 2)
        try await failEveryItemInsert(rig)

        let result = await rig.ingest.ingest(rig.image("k-7031-b", TestImage.make(width: 56, height: 44, format: .png)))

        guard case .failure(let error) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.code == .stoDb001)
        #expect(try rig.itemCount() == 2)
        #expect(rig.blobFiles() == blobsBefore)
        #expect(try rig.row(Store.id(1)).plainText == "plain neighbour")
        #expect(try rig.row(stored).copyCount == 1)
    }

    // MARK: OC-7033

    /// OC-7033. Given a copy of MARK-R1 that failed on a forced write failure and the fault then removed, when MARK-R1 is
    /// copied again, then exactly one item with that text exists (delta +1 from before the first attempt) and its
    /// copyCount is 1, and the unrelated items before and after it are untouched.
    @Test("OC-7033 a retry after a failed write creates exactly one item with copyCount 1")
    func oc7033_retryAfterFailure() async throws {
        // given three items, then a forced failure
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.store.insert([Spec(n: 1, text: "before"), Spec(n: 2, text: "middle"), Spec(n: 3, text: "after")])
        let countBefore = try rig.itemCount()
        #expect(countBefore == 3)
        try await failEveryItemInsert(rig)

        // when MARK-R1 is copied and fails, the fault is removed, and it is copied again
        let failed = await rig.ingest.ingest(rig.text("key-mark-r1", "MARK-R1"))
        guard case .failure(let error) = failed else {
            Issue.record("expected the first attempt to fail")
            return
        }
        #expect(error.code == .stoDb001)
        #expect(try rig.itemCount() == countBefore)
        try await clearFault(rig)
        let retried = try await rig.ingest.ingest(rig.text("key-mark-r1", "MARK-R1")).get()

        // then it is created once, not bumped from a half-written first attempt
        guard case .created(let id) = retried.outcome else {
            Issue.record("expected the retry to create a new item, got \(retried.outcome)")
            return
        }
        #expect(try rig.itemCount() == countBefore + 1)
        let marked = try await rig.store.reader().read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE plainText = 'MARK-R1'")!
        }
        #expect(marked == 1)
        #expect(try rig.row(id).copyCount == 1)
        #expect(try rig.row(Store.id(1)).plainText == "before")
        #expect(try rig.row(Store.id(2)).plainText == "middle")
        #expect(try rig.row(Store.id(3)).plainText == "after")
    }
}

private extension Int64 { var asInt: Int { Int(self) } }

/// Reads this process's own os_log entries written since the probe was created. The log is process-wide and Swift
/// Testing runs suites in parallel, so a test must match a fragment unique to its own action (an item id, a count no
/// other test produces) or use a lower bound ("at least N lines") that only its own action can reach.
struct ProcessLogProbe {
    private let start = Date()

    /// Composed messages of this process's log entries since `start` that contain every fragment.
    func entries(containing fragments: [String]) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let position = store.position(date: start.addingTimeInterval(-1))
        let all = (try? store.getEntries(at: position)) ?? AnySequence([])
        return all.compactMap { ($0 as? OSLogEntryLog)?.composedMessage }.filter { message in
            fragments.allSatisfy { message.contains($0) }
        }
    }

    /// Polls up to five seconds for at least `atLeast` entries containing every fragment; returns what it saw last.
    func waitForEntries(atLeast: Int = 1, containing fragments: [String]) async -> [String] {
        let deadline = Date().addingTimeInterval(5)
        var seen: [String] = []
        repeat {
            seen = entries(containing: fragments)
            if seen.count >= atLeast { return seen }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return seen
    }
}
