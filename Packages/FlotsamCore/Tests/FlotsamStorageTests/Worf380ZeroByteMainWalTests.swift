import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-380 / FR-007-13, AC-007-11: blind adversarial verification of "a zero-byte (or missing) main file beside a
// non-empty -wal is quarantined byte-identical instead of letting SQLite delete the -wal". Expected values are
// literals (hashes taken from the input before the open, names, counts, codes). Fixtures come from V370.

/// Local file system with fault injection on moves and a hook that runs when a quarantine folder is created.
final class Worf380FileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    let removed = Cell<[String]>([])
    /// Move fails when the destination's last path component is in this set.
    var failMoveNamed: Set<String> = []
    /// Runs right after a `corrupt-<ms>` folder is created, before anything is moved into it.
    var afterQuarantineCreated: @Sendable (URL) -> Void = { _ in }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> {
        let result = real.createDirectory(at: url, permissions: permissions)
        if url.lastPathComponent.hasPrefix("corrupt-") { afterQuarantineCreated(url) }
        return result
    }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> {
        if failMoveNamed.contains(destination.lastPathComponent) {
            return .failure(FlotsamError(.stoIo002, "injected move failure"))
        }
        return real.moveItem(at: source, to: destination)
    }
    func removeItem(at url: URL) -> FlotsamResult<Void> {
        removed.mutate { $0.append(url.path) }
        return real.removeItem(at: url)
    }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> {
        real.writeFile(data, to: url, permissions: permissions)
    }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { real.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { real.availableCapacity(at: url) }
}

private enum W380 {
    struct Opened {
        var failure: FlotsamError?
        var notice: FlotsamError?
        var count = -1
    }

    /// Opens, optionally runs `work` inside the session, and lets the database go before returning.
    static func open(
        _ root: URL, fs: any FileSystemPort = LocalFileSystem(), then work: ((FlotsamDatabase) async throws -> Void)? = nil
    ) async throws -> Opened {
        var opened = Opened()
        switch await FlotsamDatabase.open(folder: root, fileSystem: fs, clock: SystemClock(), migrations: Migrations.all) {
        case .failure(let error): opened.failure = error
        case .success(let db):
            opened.notice = db.openNotice
            try await work?(db)
            opened.count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") ?? -1 }
        }
        return opened
    }

    /// Every file under `root` (recursive) whose sha256 equals `sha`.
    static func filesWithSHA(_ sha: String, under root: URL) -> [String] {
        let names = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
        return names.filter { V370.sha(root.appendingPathComponent($0)) == sha }.sorted()
    }

    static func shm(_ root: URL) -> URL { root.appendingPathComponent("flotsam.sqlite-shm") }

    static func insertItem(_ db: FlotsamDatabase) async throws {
        try await db.pool.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, updatedAt, plainText)
                    VALUES ('99999999-0000-0000-0000-000000000001', 'text', 5, 5, 'marker', 5, 'marker')
                    """)
        }
    }
}

@Suite("TASK-380 adversarial: zero-byte main beside a -wal", .timeLimit(.minutes(2)))
struct Worf380ZeroByteMainWalTests {
    private func makeRoot() -> URL { V370.makeRoot() }

    /// OC-380-01: given the main file is missing entirely and a non-empty -wal sits beside it, when opened, then the
    /// -wal is quarantined byte-identical (not deleted by SQLite), STO-DB-002 is raised and a new library is open.
    /// Red if the missing-file case is treated as a fresh library (the `existed == false` path opens it first).
    @Test func missingMain_withNonEmptyWal_quarantinedByteIdentical() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        let walSha = try #require(V370.sha(V370.walURL(root)))
        try FileManager.default.removeItem(at: V370.dbURL(root))
        #expect(!FileManager.default.fileExists(atPath: V370.dbURL(root).path))

        let opened = try await W380.open(root)

        #expect(opened.failure == nil)
        #expect(opened.notice?.code == .stoDb002)
        #expect(opened.count == 0)
        let folders = V370.corruptFolders(root)
        #expect(folders.count == 1)
        guard let folder = folders.first else { return }
        #expect(V370.sha(folder.appendingPathComponent("flotsam.sqlite-wal")) == walSha)
        #expect(V370.size(V370.dbURL(root)) > 0, "a new library must be open")
    }

    /// OC-380-02: given a zero-byte main beside a non-empty -wal, when the move of ONE quarantine member fails, then
    /// the -wal is never removed and its bytes exist exactly once somewhere under the data folder; the open fails
    /// closed (STO-DB-003) rather than opening over it; and the next launch quarantines it cleanly.
    /// Red if the code removes/overwrites the -wal on failure, or opens SQLite on the pair after a failed move.
    @Test(arguments: ["flotsam.sqlite", "flotsam.sqlite-wal", "flotsam.sqlite-shm"])
    func moveFailsPartway_walNeverLost_nextLaunchRecovers(failing: String) async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        let walSha = try #require(V370.sha(V370.walURL(root)))
        try Data().write(to: V370.dbURL(root))
        try Data("shm".utf8).write(to: W380.shm(root))
        let fs = Worf380FileSystem()
        fs.failMoveNamed = [failing]

        let first = try await W380.open(root, fs: fs)

        #expect(first.failure?.code == .stoDb003, "a failed quarantine must fail closed, got \(String(describing: first.failure?.code))")
        #expect(fs.removed.value.filter { $0.hasSuffix("-wal") }.isEmpty, "the -wal must never be deleted")
        #expect(W380.filesWithSHA(walSha, under: root).count == 1, "the -wal bytes must exist exactly once")

        let second = try await W380.open(root)

        #expect(second.failure == nil)
        // The shm member moves last: when only it failed, main and -wal are already in a quarantine from the failed
        // launch and the leftover -shm alone is not damage, so the relaunch is a quiet new library.
        if failing != "flotsam.sqlite-shm" { #expect(second.notice?.code == .stoDb002) }
        #expect(second.count == 0)
        let held = W380.filesWithSHA(walSha, under: root)
        #expect(held.count == 1)
        #expect(held.first?.hasPrefix("corrupt-") == true, "after recovery the -wal sits in a quarantine, got \(held)")
        #expect(held.first?.hasSuffix("/flotsam.sqlite-wal") == true)
    }

    /// OC-380-03: given the corrupt-<ms> folder the quarantine is about to use already exists and already holds a
    /// -wal of the same name (a collision), when opened, then the earlier occupant's bytes are untouched and the new
    /// -wal bytes still exist somewhere (nothing overwritten, nothing deleted).
    /// Red if the move overwrites or removes the existing file.
    @Test func quarantineNameCollision_neverOverwritesOrLoses() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        let walSha = try #require(V370.sha(V370.walURL(root)))
        try Data().write(to: V370.dbURL(root))
        let occupant = Data("EARLIER-QUARANTINE-WAL".utf8)
        let occupantSha = try #require({ () -> String? in
            let scratch = root.appendingPathComponent("occupant.bin")
            try? occupant.write(to: scratch)
            defer { try? FileManager.default.removeItem(at: scratch) }
            return V370.sha(scratch)
        }())
        let fs = Worf380FileSystem()
        fs.afterQuarantineCreated = { folder in
            try? occupant.write(to: folder.appendingPathComponent("flotsam.sqlite-wal"))
        }

        let first = try await W380.open(root, fs: fs)

        #expect(W380.filesWithSHA(occupantSha, under: root).count == 1, "the earlier occupant must survive untouched")
        #expect(W380.filesWithSHA(walSha, under: root).count == 1, "the new -wal bytes must exist exactly once")
        if first.failure != nil { #expect(first.failure?.code == .stoDb003) }

        let second = try await W380.open(root)
        #expect(second.failure == nil)
        #expect(W380.filesWithSHA(walSha, under: root).count == 1)
        #expect(W380.filesWithSHA(occupantSha, under: root).count == 1)
    }

    /// OC-380-04: given a non-empty -wal and a zero-byte -shm beside a zero-byte main, when opened, then the -wal is
    /// byte-identical in the quarantine, the zero-byte -shm moved with it, and STO-DB-002 is raised.
    /// Red if the -shm is left behind (a stale index would then sit beside the new library) or the -wal is lost.
    @Test func zeroByteShm_movesWithWal() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        let walSha = try #require(V370.sha(V370.walURL(root)))
        try Data().write(to: V370.dbURL(root))
        try Data().write(to: W380.shm(root))

        let opened = try await W380.open(root)

        #expect(opened.failure == nil)
        #expect(opened.notice?.code == .stoDb002)
        let folders = V370.corruptFolders(root)
        #expect(folders.count == 1)
        guard let folder = folders.first else { return }
        #expect(V370.sha(folder.appendingPathComponent("flotsam.sqlite-wal")) == walSha)
        #expect(V370.size(folder.appendingPathComponent("flotsam.sqlite-shm")) == 0)
        #expect(V370.size(folder.appendingPathComponent("flotsam.sqlite")) == 0)
        #expect(V370.names(in: folder) == ["flotsam.sqlite", "flotsam.sqlite-wal", "flotsam.sqlite-shm", "blobs"])
    }

    /// OC-380-05: given blobs/ holds nested files of known bytes, when the pair is quarantined, then every blob is
    /// byte-identical under corrupt-<ms>/blobs and the live blobs/ is a fresh empty folder.
    /// Red if blobs/ is left in place, copied partially, or deleted.
    @Test func blobsPreservedByteForByte() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        try Data().write(to: V370.dbURL(root))
        let blobs = root.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs.appendingPathComponent("ab"), withIntermediateDirectories: true)
        var shas = [String: String]()
        for (name, size) in [("ab/one.bin", 1), ("ab/two.bin", 4097), ("three.bin", 100_000)] {
            let url = blobs.appendingPathComponent(name)
            try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ size) }).write(to: url)
            shas[name] = try #require(V370.sha(url))
        }

        let opened = try await W380.open(root)

        #expect(opened.notice?.code == .stoDb002)
        let folder = try #require(V370.corruptFolders(root).first)
        for (name, sha) in shas {
            #expect(V370.sha(folder.appendingPathComponent("blobs/" + name)) == sha, "\(name) differs")
        }
        #expect(shas.count == 3)
        #expect(V370.names(in: root.appendingPathComponent("blobs")).isEmpty, "the live blobs/ must be new and empty")
    }

    /// OC-380-06: given a quarantine just happened and the new library holds one item, when the app is launched
    /// again, then there is no second quarantine, no notice, and the item is still there.
    /// Red if a leftover (the new -wal, a -shm) makes the next launch quarantine again, losing the user's new item.
    @Test func relaunchAfterQuarantine_doesNotRequarantine() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        try Data().write(to: V370.dbURL(root))

        let first = try await W380.open(root) { try await W380.insertItem($0) }
        #expect(first.notice?.code == .stoDb002)
        #expect(first.count == 1)
        let quarantine = V370.corruptFolders(root)
        #expect(quarantine.count == 1)

        let second = try await W380.open(root)
        #expect(second.failure == nil)
        #expect(second.notice == nil)
        #expect(second.count == 1)
        #expect(V370.corruptFolders(root) == quarantine)

        let third = try await W380.open(root)
        #expect(third.notice == nil)
        #expect(third.count == 1)
        #expect(V370.corruptFolders(root).count == 1)
    }

    /// OC-380-07 (boundary 1 byte): given a 1-byte -wal beside a zero-byte main, then it is damage (size > 0).
    /// Red if the threshold becomes >= 32 (a real WAL header) or similar.
    @Test func oneByteWal_isDamage() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: V370.dbURL(root))
        try Data([0x7F]).write(to: V370.walURL(root))

        let opened = try await W380.open(root)

        #expect(opened.notice?.code == .stoDb002)
        let folder = try #require(V370.corruptFolders(root).first)
        #expect(V370.size(folder.appendingPathComponent("flotsam.sqlite-wal")) == 1)
    }

    /// OC-380-08 (negative): given a zero-byte main with NO -wal, or an empty -wal, then a new library opens with no
    /// quarantine and no notice (a zero-byte file is not damage).
    @Test(arguments: [false, true])
    func zeroByteMain_noOrEmptyWal_isNewLibrary(emptyWal: Bool) async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: V370.dbURL(root))
        if emptyWal { try Data().write(to: V370.walURL(root)) }

        let opened = try await W380.open(root)

        #expect(opened.failure == nil)
        #expect(opened.notice == nil)
        #expect(opened.count == 0)
        #expect(V370.corruptFolders(root).isEmpty)
    }

    /// OC-380-09 (negative, data-loss guard): given a NON-empty main file with a valid -wal holding three committed
    /// items, when opened, then nothing is quarantined and all 303 items (300 + 3 WAL-only) are served.
    /// Red if the new check keys on the -wal alone and quarantines healthy libraries.
    @Test func healthyMainWithWal_isNotQuarantined() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        #expect(V370.size(V370.dbURL(root)) > 0)

        let opened = try await W380.open(root)

        #expect(opened.failure == nil)
        #expect(opened.notice == nil)
        #expect(opened.count == 303)
        #expect(V370.corruptFolders(root).isEmpty)
    }
}
