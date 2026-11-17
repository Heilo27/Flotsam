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

    /// OC-7023. Given a blob renamed into blobs/ whose transaction never committed (the process died), when the store is
    /// reopened and reconcile runs after the blob is over 10 minutes old, then the file is gone, no row references it,
    /// the healthy item's blob stays, and STO-IO-003 was logged.
    /// Weak half: the log line carries no item id, and other suites log the same code in this process, so the log
    /// assertion can only prove "at least one more STO-IO-003 line appeared"; the file and row assertions carry the test.
    @Test("OC-7023 an orphan left by a killed ingest is removed by reconcile and logged")
    func oc7023_killedIngestOrphanIsReconciled() async throws {
        // given one stored image and a blob written by an ingest that died before its transaction
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let kept = try await rig.create(rig.image("k-7023-kept", TestImage.make(width: 40, height: 40, format: .png)))
        let keptBlob = try #require(try rig.reps(kept).first)
        let orphanId = UUID()
        let orphanName = try rig.store.database.blobs.write(Data("died-before-commit".utf8), itemId: orphanId, ordinal: 0).get()
        let orphanURL = rig.store.blobsDir.appendingPathComponent(orphanName)
        #expect(rig.store.exists(orphanURL))
        #expect(try rig.store.count("representation") == 1)
        let logged = LogProbe()

        // when 9 minutes pass, reconcile leaves it alone; when it is 11 minutes old, reconcile removes it
        rig.store.clock.advance(ms: 9 * 60_000)
        let early = try await rig.store.database.reconcile().get()
        #expect(early.orphanBlobsRemoved == 0)
        #expect(rig.store.exists(orphanURL))
        rig.store.clock.advance(ms: 2 * 60_000)
        let late = try await rig.store.database.reconcile().get()

        // then the orphan is gone and nothing else is
        #expect(late.orphanBlobsRemoved == 1)
        #expect(!rig.store.exists(orphanURL))
        #expect(rig.blobFiles() == [keptBlob.blobName])
        #expect(try rig.reps(kept) == [keptBlob])
        #expect(try rig.store.count("representation") == 1)
        #expect(try rig.store.count("item") == 1)
        #expect(await logged.sawNewLine(containing: "STO-IO-003"))
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

/// Counts STO-IO-003 lines this process has logged, so a test can see whether its own action added one. Other suites in
/// the same process log the same code, so this proves presence of a new line, not whose line it was.
private struct LogProbe {
    private let start = Date()

    func sawNewLine(containing code: String) async -> Bool {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return false }
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let position = store.position(date: start.addingTimeInterval(-1))
            let predicate = NSPredicate(format: "composedMessage CONTAINS %@", code)
            let entries = (try? store.getEntries(at: position, matching: predicate)) ?? AnySequence([])
            if entries.contains(where: { ($0 as? OSLogEntryLog)?.composedMessage.contains(code) == true }) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return false
    }
}
