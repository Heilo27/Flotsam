import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-405 / FR-007-05, blind QA strengthening. OC-405-2 in IngestPipelineTests races two real ingests and hopes the
// scheduler interleaves them so the in-transaction re-check (`.raced`) is taken; it passes whether or not it is. These
// tests take the `.raced` branch deterministically: a file-system seam runs a hook on the actor's own thread at the one
// point between step 1 (look-up found nothing) and the re-check (`DiskGuard` asks for free space), and the hook commits
// the competing item with the same contentKey. No sleeps, no scheduling luck.

/// The local file system, except that the first `availableCapacity` call after `arm` runs `hook` before answering.
/// `IngestActor.prepare` calls it after the step-1 look-up and before blobs and the insert transaction.
final class RaceHookFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var hook: (@Sendable () -> Void)?
    private var fired = 0
    private var answer: Int64?
    private var failWrites = false

    /// `capacity` is what the firing `availableCapacity` call answers (nil = unknown, the disk guard passes; a small
    /// number makes the loser hit the disk guard). `failBlobWrites` makes every `writeFile` after the hook fires fail,
    /// so the loser's blob write (step 5) fails. TASK-415.
    func arm(capacity: Int64? = nil, failBlobWrites: Bool = false, _ hook: @escaping @Sendable () -> Void) {
        lock.withLock { self.hook = hook; answer = capacity; failWrites = failBlobWrites }
    }
    var timesFired: Int { lock.withLock { fired } }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { real.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> {
        if lock.withLock({ failWrites && fired > 0 }) { return .failure(FlotsamError(.stoIo001, "Injected blob write failure")) }
        return real.writeFile(data, to: url, permissions: permissions)
    }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { real.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? {
        let pending = lock.withLock { () -> (hook: @Sendable () -> Void, answer: Int64?)? in
            guard let hook else { return nil }
            self.hook = nil
            fired += 1
            return (hook, answer)
        }
        pending?.hook()
        return pending?.answer
    }
}

@Suite(.timeLimit(.minutes(1))) struct IngestRacedNoticeTests {
    private let winnerId = UUID()

    /// Commits the "other identical payload" that won the race: one row, same contentKey, copyCount 1.
    private func armWinner(
        _ rig: Rig, _ fs: RaceHookFileSystem, key: String, kind: ItemKind, lastCopiedAt: Int64 = 1_700_000_000_000,
        capacity: Int64? = nil, failBlobWrites: Bool = false
    ) {
        let pool = rig.store.database.pool
        let id = winnerId.uuidString
        fs.arm(capacity: capacity, failBlobWrites: failBlobWrites) {
            try? pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, updatedAt)
                        VALUES (?, ?, ?, ?, ?, 'fallback', ?)
                        """,
                    arguments: [id, kind.rawValue, lastCopiedAt, lastCopiedAt, key, lastCopiedAt])
            }
        }
    }

    private func copyCount(_ rig: Rig) throws -> Int {
        try rig.store.reader().read { try Int.fetchOne($0, sql: "SELECT copyCount FROM item WHERE id = ?", arguments: [winnerId.uuidString]) ?? -1 }
    }

    /// OC-405-3. Given the competing copy commits between step 1 and the re-check of an oversized-RTF payload, when
    /// the loser reaches the re-check, then it bumps the winner and raises NO CAP-LIM-002. Goes red if `.raced` ever
    /// passes `prepared.warnings` through again (the pre-TASK-405 behaviour).
    @Test("OC-405-3 the re-check path bumps and raises no notice for an oversized-RTF payload")
    func oc405_3_racedOversizedRtf() async throws {
        // given a rig whose first free-space query commits the winner
        let fs = RaceHookFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        armWinner(rig, fs, key: "k-405-raced-rtf", kind: .richText)

        // when the loser ingests the same oversized-RTF payload
        let result = try await rig.ingest.ingest(rig.rich("k-405-raced-rtf", plain: "fallback", rtf: Data(count: 5_242_881))).get()

        // then the re-check path was really taken and nothing was raised
        #expect(fs.timesFired == 1)
        #expect(result.outcome == .bumped(winnerId))
        #expect(result.warnings.isEmpty)
        #expect(try copyCount(rig) == 2)
        #expect(try rig.itemCount() == 1)
        #expect(rig.blobFiles().isEmpty)
    }

    /// OC-405-4. Same, for the 501-member bundle (CAP-LIM-003): the re-check path raises nothing.
    @Test("OC-405-4 the re-check path bumps and raises no notice for a 501-member bundle")
    func oc405_4_racedOversizedBundle() async throws {
        let fs = RaceHookFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        armWinner(rig, fs, key: "k-405-raced-bundle", kind: .bundle)

        let result = try await rig.ingest.ingest(rig.files("k-405-raced-bundle", count: 501)).get()

        #expect(fs.timesFired == 1)
        #expect(result.outcome == .bumped(winnerId))
        #expect(result.warnings.isEmpty)
        #expect(try copyCount(rig) == 2)
        #expect(try rig.itemCount() == 1)
    }

    /// OC-405-5. A backfill (countsAsCopy false) losing the race leaves the winner untouched: `.unchanged`, copyCount
    /// still 1, no warnings. Goes red if the re-check bumps a non-copy or reports `.bumped`.
    @Test("OC-405-5 a backfill that loses the race leaves the winner unchanged and raises no notice")
    func oc405_5_racedBackfill() async throws {
        let fs = RaceHookFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        armWinner(rig, fs, key: "k-405-raced-backfill", kind: .richText)
        let base = rig.rich("k-405-raced-backfill", plain: "fallback", rtf: Data(count: 5_242_881))
        let backfill = IngestCandidate(
            kind: base.kind, contentKey: base.contentKey, plainText: base.plainText, representations: base.representations,
            origin: .screenshotFile, occurredAt: base.occurredAt, countsAsCopy: false)

        let result = try await rig.ingest.ingest(backfill).get()

        #expect(fs.timesFired == 1)
        #expect(result.outcome == .unchanged(winnerId))
        #expect(result.warnings.isEmpty)
        #expect(try copyCount(rig) == 1)
        #expect(try rig.itemCount() == 1)
    }

    /// OC-405-6. Control: with no competing row the same payload still creates the item and raises CAP-LIM-002, so
    /// "no notice" above is the bump's doing and not a notice that stopped working. The hook never fires a winner here.
    @Test("OC-405-6 the creating copy of an oversized-RTF payload still raises CAP-LIM-002 through the seam")
    func oc405_6_creatorStillNotifies() async throws {
        let fs = RaceHookFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        armWinner(rig, fs, key: "someone-else", kind: .text)   // fires, but a different key: no race for ours

        let result = try await rig.ingest.ingest(rig.rich("k-405-creator", plain: "fallback", rtf: Data(count: 5_242_881))).get()

        #expect(fs.timesFired == 1)
        guard case .created = result.outcome else { Issue.record("expected created"); return }
        #expect(result.warnings.map(\.code) == [.capLim002])
        #expect(try rig.itemCount() == 2)
    }

    // MARK: TASK-415 (W-405-2): a race loser never fails for a payload the winner already stored

    private func png() -> Data { TestImage.make(width: 64, height: 64, format: .png) }

    /// OC-415-1. The competing copy commits between step 1 and the disk guard, and the guard then refuses the loser
    /// (40 MiB free). The loser bumps the winner: one item, copyCount 2, no blob, no notice. Red if the re-check after a
    /// step 2-5 failure is removed (the loser returns STO-IO-001 for a payload that is stored).
    @Test("OC-415-1 a loser that hits the disk guard while the winner commits bumps instead of failing")
    func oc415_1_diskGuardLoser() async throws {
        let fs = RaceHookFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        armWinner(rig, fs, key: "k-415-guard", kind: .text, capacity: 40 * mib)

        let result = try await rig.ingest.ingest(rig.text("k-415-guard", "fallback")).get()

        #expect(fs.timesFired == 1)
        #expect(result.outcome == .bumped(winnerId))
        #expect(result.warnings.isEmpty)
        #expect(try copyCount(rig) == 2)
        #expect(try rig.itemCount() == 1)
        #expect(rig.blobFiles().isEmpty)
    }

    /// OC-415-2. Same race, the loser then fails the image decode (undecodable bytes, CAP-VAL-001): bumped, not failed.
    @Test("OC-415-2 a loser whose image fails to decode while the winner commits bumps instead of failing")
    func oc415_2_decodeLoser() async throws {
        let fs = RaceHookFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        armWinner(rig, fs, key: "k-415-decode", kind: .image)

        let result = try await rig.ingest.ingest(rig.image("k-415-decode", Data("not an image".utf8))).get()

        #expect(fs.timesFired == 1)
        #expect(result.outcome == .bumped(winnerId))
        #expect(result.warnings.isEmpty)
        #expect(try copyCount(rig) == 2)
        #expect(try rig.itemCount() == 1)
        #expect(rig.blobFiles().isEmpty)
    }

    /// OC-415-3. Same race, the loser's blob write (step 5) fails: bumped, with no orphan blob.
    @Test("OC-415-3 a loser whose blob write fails while the winner commits bumps instead of failing")
    func oc415_3_blobWriteLoser() async throws {
        let fs = RaceHookFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        armWinner(rig, fs, key: "k-415-blob", kind: .image, failBlobWrites: true)

        let result = try await rig.ingest.ingest(rig.image("k-415-blob", png())).get()

        #expect(fs.timesFired == 1)
        #expect(result.outcome == .bumped(winnerId))
        #expect(result.warnings.isEmpty)
        #expect(try copyCount(rig) == 2)
        #expect(try rig.itemCount() == 1)
        #expect(rig.blobFiles().isEmpty)
    }

    /// OC-415-4. A backfill (countsAsCopy false) that loses the race and hits the disk guard is `.unchanged`, not a
    /// failure and not a bump.
    @Test("OC-415-4 a backfill loser that hits the disk guard leaves the winner unchanged")
    func oc415_4_backfillGuardLoser() async throws {
        let fs = RaceHookFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        armWinner(rig, fs, key: "k-415-backfill", kind: .text, capacity: 40 * mib)
        let base = rig.text("k-415-backfill", "fallback")
        let backfill = IngestCandidate(
            kind: base.kind, contentKey: base.contentKey, plainText: base.plainText, origin: .screenshotFile,
            occurredAt: base.occurredAt, countsAsCopy: false)

        let result = try await rig.ingest.ingest(backfill).get()

        #expect(result.outcome == .unchanged(winnerId))
        #expect(try copyCount(rig) == 1)
        #expect(try rig.itemCount() == 1)
    }

    /// OC-415-5. Control: a lone payload (the competing commit has a different key) that hits the disk guard, decodes
    /// badly, or fails its blob write still fails with its own code, and stores nothing. Red if the re-check ever turns
    /// a genuine failure into a bump or a success.
    @Test("OC-415-5 a lone payload that fails steps 2 to 5 still fails with its own code")
    func oc415_5_loneFailures() async throws {
        // disk guard
        do {
            let fs = RaceHookFileSystem()
            let rig = try await Rig.make(on: fs)
            defer { rig.cleanUp() }
            armWinner(rig, fs, key: "someone-else", kind: .text, capacity: 40 * mib)
            let result = await rig.ingest.ingest(rig.text("k-415-lone-guard", "x"))
            guard case .failure(let error) = result else { Issue.record("expected the disk guard failure"); return }
            #expect(error.code == .stoIo001)
            #expect(try rig.itemCount() == 1)
            #expect(try copyCount(rig) == 1)
            #expect(rig.blobFiles().isEmpty)
        }
        // decode
        do {
            let fs = RaceHookFileSystem()
            let rig = try await Rig.make(on: fs)
            defer { rig.cleanUp() }
            armWinner(rig, fs, key: "someone-else", kind: .text)
            let result = await rig.ingest.ingest(rig.image("k-415-lone-decode", Data("not an image".utf8)))
            guard case .failure(let error) = result else { Issue.record("expected the decode failure"); return }
            #expect(error.code == .capVal001)
            #expect(try rig.itemCount() == 1)
        }
        // blob write
        do {
            let fs = RaceHookFileSystem()
            let rig = try await Rig.make(on: fs)
            defer { rig.cleanUp() }
            armWinner(rig, fs, key: "someone-else", kind: .text, failBlobWrites: true)
            let result = await rig.ingest.ingest(rig.image("k-415-lone-blob", png()))
            guard case .failure(let error) = result else { Issue.record("expected the blob write failure"); return }
            #expect(error.code == .stoIo001)
            #expect(try rig.itemCount() == 1)
            #expect(rig.blobFiles().isEmpty)
        }
    }
}
