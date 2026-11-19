import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-415 blind QA (Worf). The builder's OC-415 set leaves two behaviours in `bumpOrFail` / `writeBlobs` unpinned:
// the re-check's own database failure, and cleanup of a blob already written when a LATER blob of the same item
// fails. Both seams reuse `RaceHookFileSystem` (IngestRacedNoticeTests.swift).

/// `RaceHookFileSystem`, except that once its hook has fired the SECOND `writeFile` fails (the first succeeds).
final class SecondWriteFailsFileSystem: FileSystemPort, @unchecked Sendable {
    let inner = RaceHookFileSystem()
    private let lock = NSLock()
    private var writesAfterFire = 0

    func fileExists(at url: URL) -> Bool { inner.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { inner.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { inner.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { inner.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with source: URL) -> FlotsamResult<Void> { inner.replaceItem(at: destination, with: source) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { inner.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { inner.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { inner.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> {
        let nth = lock.withLock { () -> Int in
            guard inner.timesFired > 0 else { return 0 }
            writesAfterFire += 1
            return writesAfterFire
        }
        if nth == 2 { return .failure(FlotsamError(.stoIo001, "Injected second blob write failure")) }
        return inner.writeFile(data, to: url, permissions: permissions)
    }
    func readFile(at url: URL) -> FlotsamResult<Data> { inner.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { inner.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { inner.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { inner.availableCapacity(at: url) }
}

/// The local file system, except that the first `writeFile` runs `hook` before writing: the point AFTER the loser's
/// step-5 blob write begins and BEFORE the step-6 transaction, which `RaceHookFileSystem` cannot reach.
final class FirstWriteHookFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var hook: (@Sendable () -> Void)?
    func arm(_ hook: @escaping @Sendable () -> Void) { lock.withLock { self.hook = hook } }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with source: URL) -> FlotsamResult<Void> { real.replaceItem(at: destination, with: source) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { real.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> {
        let pending = lock.withLock { () -> (@Sendable () -> Void)? in defer { hook = nil }; return hook }
        pending?()
        return real.writeFile(data, to: url, permissions: permissions)
    }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { real.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { nil }
}

@Suite(.timeLimit(.minutes(1))) struct IngestRacedLoserWorf415Tests {
    private let winnerId = UUID()

    private func winnerRow(_ pool: DatabasePool, key: String, kind: ItemKind) -> @Sendable () -> Void {
        let id = winnerId.uuidString
        return {
            try? pool.write { db in
                try db.execute(
                    sql: "INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, updatedAt) VALUES (?, ?, 1, 1, ?, 'p', 1)",
                    arguments: [id, kind.rawValue, key])
            }
        }
    }

    /// OC-415-W1. Given the winner commits and the loser then fails the disk guard, and the re-check's own lookup
    /// throws (the `item` table is renamed away by the hook), when the loser reports, then it returns the ORIGINAL
    /// failure (STO-IO-001, the guard's), not the lookup's STO-DB-001, and logs the lookup error once; no blob.
    /// Red if bumpOrFail returns `.failure(lookupError)` or drops `database.report(lookupError)`.
    @Test("OC-415-W1 a re-check that itself fails reports the original failure and logs the lookup error")
    func w1_recheckDatabaseError() async throws {
        // given
        let fs = RaceHookFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        let pool = rig.store.database.pool
        fs.arm(capacity: 40 * mib) { try? pool.write { try $0.execute(sql: "ALTER TABLE item RENAME TO itemGone") } }
        let before = rig.store.logs.lines(containing: ["STO-DB-001"]).count

        // when
        let result = await rig.ingest.ingest(rig.text("k-415-w1", "x"))

        // then
        #expect(fs.timesFired == 1)
        guard case .failure(let error) = result else { Issue.record("expected the original failure"); return }
        #expect(error.code == .stoIo001)
        #expect(rig.store.logs.lines(containing: ["STO-DB-001"]).count - before == 1)
        #expect(rig.blobFiles().isEmpty)
    }

    /// OC-415-W2. Given a two-blob payload (RTF and HTML) whose second blob write fails after the winner committed,
    /// when the loser reports, then it bumps (count 2, one item) and the FIRST blob it already wrote is gone, in
    /// blobs/ and in tmp/. Red if `writeBlobs` stops removing blobs already written on a later failure.
    @Test("OC-415-W2 a loser whose second blob write fails leaves no first blob behind and bumps")
    func w2_secondBlobWriteFails() async throws {
        // given
        let fs = SecondWriteFailsFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        fs.inner.arm(winnerRow(rig.store.database.pool, key: "k-415-w2", kind: .richText))
        let candidate = IngestCandidate(
            kind: .richText, contentKey: "k-415-w2", plainText: "p",
            representations: [
                PasteboardRepresentation(uti: "public.rtf", data: Data("rtf".utf8)),
                PasteboardRepresentation(uti: "public.html", data: Data("html".utf8)),
            ],
            origin: .pasteboard, occurredAt: Date(timeIntervalSince1970: 2_000_000))

        // when
        let result = try await rig.ingest.ingest(candidate).get()

        // then
        #expect(result.outcome == .bumped(winnerId))
        #expect(result.warnings.isEmpty)
        let copies = try await rig.store.reader().read { try Int.fetchOne($0, sql: "SELECT copyCount FROM item WHERE id = ?", arguments: [winnerId.uuidString]) }
        #expect(copies == 2)
        #expect(try rig.itemCount() == 1)
        #expect(rig.blobFiles().isEmpty)
        let tmp = (try? FileManager.default.contentsOfDirectory(atPath: rig.store.root.appendingPathComponent("tmp").path)) ?? []
        #expect(tmp.isEmpty)
    }

    /// OC-415-W3. Control for W2: with no winner, the same second-write failure is the loser-less failure STO-IO-001,
    /// nothing stored, and still no blob left. Red if the cleanup is skipped OR the failure is swallowed.
    @Test("OC-415-W3 a lone two-blob payload whose second write fails fails and leaves no blob")
    func w3_loneSecondBlobWriteFails() async throws {
        let fs = SecondWriteFailsFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        fs.inner.arm(winnerRow(rig.store.database.pool, key: "someone-else", kind: .text))
        let candidate = IngestCandidate(
            kind: .richText, contentKey: "k-415-w3", plainText: "p",
            representations: [
                PasteboardRepresentation(uti: "public.rtf", data: Data("rtf".utf8)),
                PasteboardRepresentation(uti: "public.html", data: Data("html".utf8)),
            ],
            origin: .pasteboard, occurredAt: Date(timeIntervalSince1970: 2_000_000))

        let result = await rig.ingest.ingest(candidate)

        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == .stoIo001)
        #expect(try rig.itemCount() == 1)
        #expect(rig.blobFiles().isEmpty)
    }

    /// OC-415-W4. A plain text over the 10 MiB ceiling fails with CAP-LIM-001 (step 2, before the seam can fire) and
    /// stores nothing: the limits branch of bumpOrFail's caller returns its own code when no copy of it is stored.
    @Test("OC-415-W4 an over-ceiling plain text alone still fails CAP-LIM-001 and stores nothing")
    func w4_limitsFailureAlone() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }

        let result = await rig.ingest.ingest(rig.text("k-415-w4", String(repeating: "a", count: 10 * 1024 * 1024 + 1)))

        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == .capLim001)
        #expect(try rig.itemCount() == 0)
    }

    /// OC-415-W5. Given the winner commits after the loser has begun its blob writes (so the loser is past every
    /// step 2-5 failure point), when the loser reaches the step-6 transaction, then it bumps and removes the blobs it
    /// wrote. Red if the `.raced` branch stops calling `removeBlobs` (an orphan blob per lost race).
    @Test("OC-415-W5 a loser that hits the step-6 re-check after writing its blobs removes them and bumps")
    func w5_racedAfterBlobWrite() async throws {
        // given
        let fs = FirstWriteHookFileSystem()
        let rig = try await Rig.make(on: fs)
        defer { rig.cleanUp() }
        fs.arm(winnerRow(rig.store.database.pool, key: "k-415-w5", kind: .image))

        // when
        let result = try await rig.ingest.ingest(rig.image("k-415-w5", TestImage.make(width: 64, height: 64, format: .png))).get()

        // then
        #expect(result.outcome == .bumped(winnerId))
        #expect(result.warnings.isEmpty)
        let copies = try await rig.store.reader().read { try Int.fetchOne($0, sql: "SELECT copyCount FROM item WHERE id = ?", arguments: [winnerId.uuidString]) }
        #expect(copies == 2)
        #expect(try rig.itemCount() == 1)
        #expect(rig.blobFiles().isEmpty)
    }
}
