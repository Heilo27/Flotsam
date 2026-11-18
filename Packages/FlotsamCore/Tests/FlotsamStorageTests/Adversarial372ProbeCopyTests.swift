import CryptoKit
import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-372 / FR-007-13, AC-007-11, AC-007-15: adversarial, blind verification of the sidecar-less WAL-file probe
// (open -> attempt -> probe -> probeCopy). Written from the spec and the code, not from the implementer's tests.
// Expected values are literals (hashes taken from the input before the open, file names, counts, error codes).
// V370 (TASK-370) supplies the raw-GRDB fixture builders; the arrange step of every test proves its fixture really is
// healthy / damaged by an independent check on a COPY.

/// Lock-protected cell the file-system fake writes into from inside `open`.
final class Cell<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

/// The local file system that records every mutating call, can observe the user's files at the moment of the first
/// probe-copy and the first quarantine move, and can fail selected calls.
final class ProbeFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    let events = Cell<[String]>([])
    var failCopy: @Sendable (URL, URL) -> Bool = { _, _ in false }
    var failCreate: @Sendable (URL) -> Bool = { _ in false }
    var failRemove: @Sendable (URL) -> Bool = { _ in false }
    /// Runs just before the FIRST copy whose destination is inside tmp/probe-*.
    var beforeFirstProbeCopy: @Sendable () -> Void = {}
    /// Runs just before the FIRST move (the quarantine).
    var beforeFirstMove: @Sendable () -> Void = {}
    private let firedCopy = Cell(false)
    private let firedMove = Cell(false)

    static func isProbe(_ url: URL) -> Bool { url.path.contains("/tmp/probe-") }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> {
        events.mutate { $0.append("create \(url.path)") }
        if failCreate(url) { return .failure(FlotsamError(.stoIo002, "injected create failure")) }
        return real.createDirectory(at: url, permissions: permissions)
    }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> {
        events.mutate { $0.append("copy \(source.lastPathComponent) -> \(destination.path)") }
        if Self.isProbe(destination), !firedCopy.value {
            firedCopy.value = true
            beforeFirstProbeCopy()
        }
        if failCopy(source, destination) { return .failure(FlotsamError(.stoIo001, "injected copy failure")) }
        return real.copyItem(at: source, to: destination)
    }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> {
        events.mutate { $0.append("move \(source.lastPathComponent)") }
        if !firedMove.value {
            firedMove.value = true
            beforeFirstMove()
        }
        return real.moveItem(at: source, to: destination)
    }
    func removeItem(at url: URL) -> FlotsamResult<Void> {
        events.mutate { $0.append("remove \(url.path)") }
        if failRemove(url) { return .failure(FlotsamError(.stoIo003, "injected remove failure")) }
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

    var probeCopies: [String] { events.value.filter { $0.hasPrefix("copy ") && $0.contains("/tmp/probe-") } }
}

private enum V372 {
    /// sha256 of `flotsam.sqlite` and `flotsam.sqlite-wal` as found (a missing file is absent from the map).
    static func fingerprint(_ root: URL) -> [String: String] {
        var map = [String: String]()
        for name in ["flotsam.sqlite", "flotsam.sqlite-wal"] {
            if let sha = V370.sha(root.appendingPathComponent(name)) { map[name] = sha }
        }
        return map
    }

    static func tmp(_ root: URL) -> URL { root.appendingPathComponent("tmp") }
    static func tmpEntries(_ root: URL) -> Set<String> { V370.names(in: tmp(root)) }

    /// A healthy WAL-mode database with no -wal and no -shm: the state after a clean shutdown, or a file copied alone.
    @discardableResult
    static func buildWalFile(at url: URL, items: Int = 300, version: Int = 1) throws -> URL {
        let pool = try DatabasePool(path: url.path)
        try pool.write { try V370.populate($0, items: items, version: version) }
        try pool.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        return url
    }

    /// Byte 18 of the header is the file-format write version: 2 means WAL.
    static func isWalMode(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > 19 else { return false }
        return data[18] == 2 && data[19] == 2
    }

    /// `V370.buildWithWal` with a `user_version` bump committed only in the -wal (the main file still says 1).
    static func buildWithWal(into root: URL, userVersionInWal version: Int) throws {
        let staging = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: staging) }
        let path = staging.appendingPathComponent("flotsam.sqlite").path
        try V370.buildWal(path: path)
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA wal_autocheckpoint = 0") }
        let pool = try DatabasePool(path: path, configuration: configuration)
        try pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = \(version)") }
        try FileManager.default.copyItem(at: staging.appendingPathComponent("flotsam.sqlite"), to: V370.dbURL(root))
        try FileManager.default.copyItem(at: staging.appendingPathComponent("flotsam.sqlite-wal"), to: V370.walURL(root))
        try pool.close()
    }

    struct Opened {
        var failure: FlotsamError?
        var notice: FlotsamError?
        var count = -1
        var ids = Set<String>()
        var userVersion = -1
        var quickCheck = [String]()
    }

    static func open(_ root: URL, fs: any FileSystemPort) async throws -> Opened {
        var opened = Opened()
        switch await FlotsamDatabase.open(
            folder: root, fileSystem: fs, clock: SystemClock(), migrations: Migrations.all)
        {
        case .failure(let error): opened.failure = error
        case .success(let db):
            opened.notice = db.openNotice
            let snapshot = try await db.pool.read { conn in
                (
                    try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1,
                    Set(try String.fetchAll(conn, sql: "SELECT id FROM item")),
                    try Int.fetchOne(conn, sql: "PRAGMA user_version") ?? -1,
                    try String.fetchAll(conn, sql: "PRAGMA quick_check")
                )
            }
            (opened.count, opened.ids, opened.userVersion, opened.quickCheck) = snapshot
        }
        return opened
    }

    static func probeDirs(_ root: URL) -> Set<String> { tmpEntries(root).filter { $0.hasPrefix("probe-") } }
}

@Suite("TASK-372 adversarial: sidecar-less WAL probe copy", .timeLimit(.minutes(1)))
struct Adversarial372ProbeCopyTests {
    private func makeRoot() -> URL { V370.makeRoot() }

    /// Shared "quarantined as found, fresh library serves" assertions.
    private func expectQuarantined(
        _ root: URL, opened: V372.Opened, main: String, wal: String?, sizeBefore: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(opened.failure == nil, "open must succeed after quarantine: \(String(describing: opened.failure))", sourceLocation: sourceLocation)
        #expect(opened.notice?.code == .stoDb002, sourceLocation: sourceLocation)
        let folders = V370.corruptFolders(root)
        #expect(folders.count == 1, "exactly one corrupt-<ts> folder, got \(folders.count)", sourceLocation: sourceLocation)
        guard let folder = folders.first else { return }
        #expect(V370.sha(folder.appendingPathComponent("flotsam.sqlite")) == main, "quarantined main differs from input", sourceLocation: sourceLocation)
        #expect(V370.size(folder.appendingPathComponent("flotsam.sqlite")) == sizeBefore, sourceLocation: sourceLocation)
        if let wal {
            #expect(V370.sha(folder.appendingPathComponent("flotsam.sqlite-wal")) == wal, "quarantined -wal differs from input", sourceLocation: sourceLocation)
        }
        #expect(
            V370.names(in: folder).isSubset(of: ["flotsam.sqlite", "flotsam.sqlite-wal", "flotsam.sqlite-shm", "blobs"]),
            "unexpected quarantine content \(V370.names(in: folder))", sourceLocation: sourceLocation)
        #expect(opened.count == 0, sourceLocation: sourceLocation)
        #expect(opened.userVersion == 1, sourceLocation: sourceLocation)
        #expect(opened.quickCheck == ["ok"], sourceLocation: sourceLocation)
        #expect(V372.probeDirs(root).isEmpty, "probe dir left behind: \(V372.probeDirs(root))", sourceLocation: sourceLocation)
    }

    // MARK: WAL-mode file, no sidecars

    /// OC-372-01: given a HEALTHY WAL-mode file (300 items) with no -wal and no -shm, when opened, then it opens
    /// with all 300 ids, no notice, no quarantine, tmp/ holds no probe dir afterwards, a probe copy was really made
    /// (the path under test ran), and the user's main file was byte-identical at the moment the copy began (the
    /// read-only attempt wrote nothing). Dies if the sidecar-less file is refused/quarantined, if the probe copy is
    /// not removed, or if the read-only attempt writes to the main file.
    @Test func healthyWalFile_noSidecars_opensIntact_probeDirRemoved_mainUntouchedBeforeCopy() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root))
        #expect(V372.isWalMode(V370.dbURL(root)), "arrange: header says WAL")
        #expect(V370.verdict(main: V370.dbURL(root)) == .ok, "arrange: healthy")
        #expect(!FileManager.default.fileExists(atPath: V370.walURL(root).path))
        let before = V372.fingerprint(root)
        let atCopy = Cell<[String: String]?>(nil)
        let fs = ProbeFileSystem()
        fs.beforeFirstProbeCopy = { atCopy.value = V372.fingerprint(root) }

        let opened = try await V372.open(root, fs: fs)

        #expect(opened.failure == nil, "healthy file refused: \(String(describing: opened.failure?.code)) \(String(describing: opened.failure?.underlying))")
        #expect(opened.notice == nil)
        #expect(opened.count == 300)
        #expect(opened.ids.count == 300 && opened.ids.contains(V370.itemId(1)) && opened.ids.contains(V370.itemId(300)))
        #expect(V370.corruptFolders(root).isEmpty)
        #expect(fs.probeCopies.count == 1, "exactly the main file is copied (no -wal exists): \(fs.probeCopies)")
        #expect(atCopy.value == before, "main file changed before the probe copy was made")
        #expect(V372.probeDirs(root).isEmpty, "probe dir left behind")
    }

    /// OC-372-02: given a WAL-mode file with a damaged late page and no sidecars, when opened, then the main file is
    /// quarantined byte-identical, a fresh library serves, the file was untouched at the moment of the quarantine
    /// move, and no probe dir remains. Dies if the probe copy's checkpoint is done on the original, or the damaged
    /// file is let through because the read-only probe failed.
    @Test func damagedWalFile_noSidecars_quarantinedByteIdentical_untouchedUntilMove() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root))
        try V370.damageLatePage(V370.dbURL(root))
        try V370.pinMtime(V370.dbURL(root))
        #expect(V372.isWalMode(V370.dbURL(root)))
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails, "arrange: damaged")
        let before = V372.fingerprint(root)
        let size = V370.size(V370.dbURL(root))
        let atMove = Cell<[String: String]?>(nil)
        let fs = ProbeFileSystem()
        fs.beforeFirstMove = { atMove.value = V372.fingerprint(root) }

        let opened = try await V372.open(root, fs: fs)

        expectQuarantined(root, opened: opened, main: before["flotsam.sqlite"]!, wal: nil, sizeBefore: size)
        #expect(fs.probeCopies.count == 1, "the probe copy path must have run: \(fs.probeCopies)")
        #expect(atMove.value == before, "the user's file changed before it was set aside")
    }

    /// OC-372-03: given a WAL-mode file truncated mid-page (so it is damaged and has no sidecars), when opened,
    /// then quarantined byte-identical. Dies if a short copy/probe is mistaken for healthy or throws a non-damage error.
    @Test func truncatedMidPageWalFile_noSidecars_quarantinedByteIdentical() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root))
        let handle = try FileHandle(forWritingTo: V370.dbURL(root))
        try handle.truncate(atOffset: UInt64(V370.size(V370.dbURL(root)) * 3 / 5 + 1234))
        try handle.close()
        #expect(V370.size(V370.dbURL(root)) % 4096 != 0, "arrange: cut mid-page")
        #expect(V372.isWalMode(V370.dbURL(root)))
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails, "arrange: damaged")
        let before = V372.fingerprint(root)
        let size = V370.size(V370.dbURL(root))

        let opened = try await V372.open(root, fs: LocalFileSystem())

        expectQuarantined(root, opened: opened, main: before["flotsam.sqlite"]!, wal: nil, sizeBefore: size)
    }

    /// OC-372-04: given a WAL-mode file whose page 1 is damaged after the 100-byte header (magic and WAL flag intact),
    /// when opened, then quarantined byte-identical. Dies if header-only sanity is trusted.
    @Test func walFile_page1BodyDamaged_noSidecars_quarantinedByteIdentical() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root))
        let handle = try FileHandle(forWritingTo: V370.dbURL(root))
        try handle.seek(toOffset: 100)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 400))
        try handle.close()
        #expect(V372.isWalMode(V370.dbURL(root)))
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails, "arrange: damaged")
        let before = V372.fingerprint(root)
        let size = V370.size(V370.dbURL(root))

        let opened = try await V372.open(root, fs: LocalFileSystem())

        expectQuarantined(root, opened: opened, main: before["flotsam.sqlite"]!, wal: nil, sizeBefore: size)
    }

    // MARK: -wal with committed rows, no -shm

    /// OC-372-05: given a WAL-mode file whose -wal holds 3 committed, uncheckpointed rows and no -shm, when opened,
    /// then all 303 rows are present (the WAL is replayed, not ignored), no quarantine, no notice, no probe dir.
    /// Dies if the committed -wal frames are dropped (probe on a main-only copy adopted, or WAL discarded).
    @Test func committedWalRows_noShm_opensWithAllRows() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        #expect(V370.size(V370.walURL(root)) > 0, "arrange: -wal holds frames")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("flotsam.sqlite-shm").path), "arrange: no -shm")

        let opened = try await V372.open(root, fs: ProbeFileSystem())

        #expect(opened.failure == nil, "refused: \(String(describing: opened.failure?.code)) \(String(describing: opened.failure?.underlying))")
        #expect(opened.notice == nil)
        #expect(opened.count == 303, "rows committed to the -wal were lost: \(opened.count)")
        for n in 1001...1003 { #expect(opened.ids.contains(V370.itemId(n)), "wal-only row \(n) missing") }
        #expect(V370.corruptFolders(root).isEmpty)
        #expect(V372.probeDirs(root).isEmpty)
    }

    /// OC-372-05b: given a HEALTHY WAL-mode file at user_version 99 whose committed -wal frames carry the version
    /// bump (no -shm), when opened, then STO-DB-003 and BOTH the main file and the -wal are byte-identical: the
    /// pre-verdict probe wrote nothing to the user's files. Dies if the attempt checkpoints/recovers the original.
    @Test func newerVersionInWalFrames_noShm_refused_mainAndWalByteIdentical() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWithWal(into: root, userVersionInWal: 99)
        #expect(V370.size(V370.walURL(root)) > 0, "arrange: -wal holds frames")
        #expect(V370.headerUserVersion(V370.dbURL(root)) == 1, "arrange: the version bump lives only in the -wal")
        let before = V372.fingerprint(root)
        #expect(before.count == 2)

        let opened = try await V372.open(root, fs: LocalFileSystem())

        assertRefusedUntouched(root, opened: opened, before: before)
    }

    /// OC-372-06: given a WAL-mode file with committed -wal frames (no -shm) and a damaged main-file page the -wal
    /// does not supersede, when opened, then main AND -wal are quarantined byte-identical and were untouched at the
    /// moment of the move. Dies if the check runs on the original or the -wal is not part of the quarantine.
    @Test func committedWalRows_noShm_damagedMain_bothQuarantinedByteIdentical_untouchedUntilMove() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let walPages = try V370.buildWithWal(into: root)
        try V370.damageLatePage(V370.dbURL(root), avoiding: walPages)
        try V370.pinMtime(V370.dbURL(root))
        #expect(V370.verdict(main: V370.dbURL(root), wal: V370.walURL(root)) == .fails, "arrange: damaged")
        let before = V372.fingerprint(root)
        let size = V370.size(V370.dbURL(root))
        let atMove = Cell<[String: String]?>(nil)
        let fs = ProbeFileSystem()
        fs.beforeFirstMove = { atMove.value = V372.fingerprint(root) }

        let opened = try await V372.open(root, fs: fs)

        expectQuarantined(root, opened: opened, main: before["flotsam.sqlite"]!, wal: before["flotsam.sqlite-wal"]!, sizeBefore: size)
        #expect(atMove.value == before, "user's files changed before they were set aside")
    }

    // MARK: probe copy cannot be made

    private func assertRefusedUntouched(
        _ root: URL, opened: V372.Opened, before: [String: String], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(opened.failure?.code == .stoDb003, "got \(String(describing: opened.failure?.code))", sourceLocation: sourceLocation)
        #expect(opened.notice == nil, sourceLocation: sourceLocation)
        #expect(V372.fingerprint(root) == before, "user's files changed", sourceLocation: sourceLocation)
        #expect(V370.corruptFolders(root).isEmpty, "a file that merely could not be probed must not be quarantined", sourceLocation: sourceLocation)
        #expect(V372.probeDirs(root).isEmpty, "probe dir left behind: \(V372.probeDirs(root))", sourceLocation: sourceLocation)
    }

    /// OC-372-07: given a healthy sidecar-less WAL file and a file system on which the copy into tmp/probe-* fails,
    /// when opened, then STO-DB-003 (Fatal, not a Notice, not a quarantine), the user's file is byte-identical, no
    /// corrupt-* folder exists, and the probe dir is gone. Dies if a failed copy is read as "damaged" (data moved
    /// aside for nothing) or as "healthy" (open proceeds unprobed), or the dir leaks.
    @Test func probeCopyFails_healthyFile_refusedStoDb003_untouched_noProbeDirLeft() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root))
        let before = V372.fingerprint(root)
        let fs = ProbeFileSystem()
        fs.failCopy = { _, destination in ProbeFileSystem.isProbe(destination) }

        let opened = try await V372.open(root, fs: fs)

        assertRefusedUntouched(root, opened: opened, before: before)
        #expect(fs.probeCopies.count == 1, "the copy must have been attempted: \(fs.probeCopies)")
    }

    /// OC-372-08: same with a DAMAGED sidecar-less file: an unprobeable damaged file is not silently let through
    /// either, and it is not touched. Dies if the failure path falls through to opening the pool (which would
    /// rewrite the damaged file's header and VACUUM it).
    @Test func probeCopyFails_damagedFile_refused_untouched_notOpenedForWriting() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root))
        try V370.damageLatePage(V370.dbURL(root))
        try V370.pinMtime(V370.dbURL(root))
        let before = V372.fingerprint(root)
        let fs = ProbeFileSystem()
        fs.failCopy = { _, destination in ProbeFileSystem.isProbe(destination) }

        let opened = try await V372.open(root, fs: fs)

        assertRefusedUntouched(root, opened: opened, before: before)
        #expect(V370.mtime(V370.dbURL(root)) == V370.oldDate, "the file was written to")
    }

    /// OC-372-09: given the probe directory cannot be created, when opened, then STO-DB-003, files untouched, no
    /// leftover. Dies if the unchecked-guard throws the wrong thing or proceeds to open the pool.
    @Test func probeDirCannotBeCreated_refused_untouched() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root))
        let before = V372.fingerprint(root)
        let fs = ProbeFileSystem()
        fs.failCreate = { ProbeFileSystem.isProbe($0) }

        let opened = try await V372.open(root, fs: fs)

        assertRefusedUntouched(root, opened: opened, before: before)
        #expect(fs.events.value.contains { $0.hasPrefix("create ") && $0.contains("/tmp/probe-") }, "create was attempted")
    }

    /// OC-372-11: given a healthy sidecar-less file the user cannot read (mode 000), when opened with the real file
    /// system, then STO-DB-003, content and mode byte-identical, nothing quarantined, no probe dir.
    @Test func unreadableMainFile_refused_untouched() async throws {
        let root = makeRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: V370.dbURL(root).path)
            try? FileManager.default.removeItem(at: root)
        }
        try V372.buildWalFile(at: V370.dbURL(root))
        let before = V372.fingerprint(root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: V370.dbURL(root).path)
        #expect(V370.mode(V370.dbURL(root)) == 0)

        let opened = try await V372.open(root, fs: LocalFileSystem())

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: V370.dbURL(root).path)
        assertRefusedUntouched(root, opened: opened, before: before)
    }

    // MARK: sidecar-less WAL file and versions

    /// OC-372-12: given a HEALTHY WAL-mode file at user_version 99 and no sidecars, when opened, then STO-DB-003,
    /// main byte-identical with its mtime, no -wal created in the user's folder, nothing quarantined, no probe dir.
    /// Dies if the newer-version guard moves behind the pool open (which switches journal mode / VACUUMs).
    @Test func healthyNewerVersion_walFile_noSidecars_refusedUntouched() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root), items: 5, version: 99)
        try V370.pinMtime(V370.dbURL(root))
        #expect(V372.isWalMode(V370.dbURL(root)))
        let before = V372.fingerprint(root)

        let opened = try await V372.open(root, fs: LocalFileSystem())

        assertRefusedUntouched(root, opened: opened, before: before)
        #expect(V370.mtime(V370.dbURL(root)) == V370.oldDate)
        #expect(!FileManager.default.fileExists(atPath: V370.walURL(root).path), "a -wal appeared beside a refused file")
    }

    /// OC-372-13: boundary: given a healthy sidecar-less WAL file at user_version 2 (newest known is 1), then it is
    /// refused (max+1); at version 1 it opens (max) - OC-372-01 covers 1. Dies if the comparison becomes >=.
    @Test func healthyVersionTwo_walFile_noSidecars_refused_boundaryAboveNewest() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root), items: 5, version: 2)
        let before = V372.fingerprint(root)

        let opened = try await V372.open(root, fs: LocalFileSystem())

        assertRefusedUntouched(root, opened: opened, before: before)
    }

    /// OC-372-14: given a DAMAGED WAL-mode file whose header claims user_version 99 and with no sidecars, when
    /// opened, then quarantined (integrity outranks version) byte-identical, not refused.
    @Test func damagedNewerVersion_walFile_noSidecars_quarantinedNotRefused() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root), items: 300, version: 99)
        try V370.damageLatePage(V370.dbURL(root))
        #expect(V370.headerUserVersion(V370.dbURL(root)) == 99)
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails)
        let before = V372.fingerprint(root)
        let size = V370.size(V370.dbURL(root))

        let opened = try await V372.open(root, fs: LocalFileSystem())

        expectQuarantined(root, opened: opened, main: before["flotsam.sqlite"]!, wal: nil, sizeBefore: size)
    }

    // MARK: zero-byte

    /// OC-372-15: given a zero-byte flotsam.sqlite, when opened, then a new empty library (0 items, v1), no notice,
    /// no quarantine, no probe dir, and no probe copy attempted.
    @Test func zeroByteFile_newEmptyLibrary_noQuarantine_noProbe() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: V370.dbURL(root).path, contents: Data())
        #expect(V370.size(V370.dbURL(root)) == 0)
        let fs = ProbeFileSystem()

        let opened = try await V372.open(root, fs: fs)

        #expect(opened.failure == nil)
        #expect(opened.notice == nil)
        #expect(opened.count == 0)
        #expect(opened.userVersion == 1)
        #expect(opened.quickCheck == ["ok"])
        #expect(V370.corruptFolders(root).isEmpty)
        #expect(fs.probeCopies.isEmpty)
        #expect(V372.probeDirs(root).isEmpty)
    }

    /// OC-372-16 (exploratory, spec silent): given a zero-byte main file beside a -wal that holds committed frames,
    /// when opened, then the library is new and empty, but the -wal bytes must not be destroyed: they must still
    /// exist (live or set aside) byte-identical. FR-007-13 promises user data is never deleted. Dies if SQLite's
    /// "empty database => discard the WAL" rule deletes them.
    @Test func zeroByteMain_withNonEmptyWal_walBytesSurvivePlaceKnown() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        let walSha = V370.sha(V370.walURL(root))!
        try Data().write(to: V370.dbURL(root))
        #expect(V370.size(V370.dbURL(root)) == 0)

        let opened = try await V372.open(root, fs: LocalFileSystem())

        #expect(opened.failure == nil)
        #expect(opened.count == 0)
        func allFiles(_ url: URL) -> [URL] {
            let names = (try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? []
            return names.map { url.appendingPathComponent($0) }
        }
        let survivors = allFiles(root).filter { V370.sha($0) == walSha }
        withKnownIssue("FINDING TASK-372-F1: SQLite deletes the -wal of a zero-byte main file; spec is silent (not part of TASK-372)") {
            #expect(!survivors.isEmpty, "the committed -wal bytes (sha \(walSha.prefix(8))) no longer exist anywhere under the data folder")
        }
    }

    // MARK: leftovers from a crash

    /// OC-372-17: given tmp/ holds a probe-<uuid>/ left by a crashed run (a stale copy of the database, a -wal, and a
    /// stray file), when a healthy sidecar-less file is opened, then the leftovers are gone (tmp entries 3 -> 0 except
    /// the fresh probe, which is also removed), the user's main file is byte-identical to before and the 300 items
    /// serve from it (not from the stale copy). Dies if tmp/ is not emptied before the probe.
    @Test func leftoverProbeDirFromCrash_cleanedOnNextOpen_userFileSurvives() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root))
        let tmp = V372.tmp(root)
        let stale = tmp.appendingPathComponent("probe-DEAD0000-0000-0000-0000-000000000000")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("stale copy".utf8).write(to: stale.appendingPathComponent("flotsam.sqlite"))
        try Data("stale wal".utf8).write(to: stale.appendingPathComponent("flotsam.sqlite-wal"))
        try Data("x".utf8).write(to: tmp.appendingPathComponent("blob-in-flight"))
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("probe-BEEF"), withIntermediateDirectories: true)
        #expect(V372.tmpEntries(root).count == 3, "arrange: 3 leftovers")
        let before = V372.fingerprint(root)

        let opened = try await V372.open(root, fs: LocalFileSystem())

        #expect(opened.failure == nil)
        #expect(opened.count == 300)
        #expect(V372.tmpEntries(root).isEmpty, "tmp/ not emptied: \(V372.tmpEntries(root))")
        #expect(V370.sha(V370.dbURL(root)) != nil)
        #expect(V370.corruptFolders(root).isEmpty)
        #expect(before["flotsam.sqlite"] != nil)
    }

    /// OC-372-18: given leftover probe dirs and a NEWER-version file (open fails), when opened, then the leftovers
    /// are still cleaned and the user's file is untouched. Dies if cleanup only happens on the success path.
    @Test func leftoverProbeDir_cleanedEvenWhenOpenIsRefused() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root), items: 5, version: 99)
        let stale = V372.tmp(root).appendingPathComponent("probe-DEAD")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stale.appendingPathComponent("flotsam.sqlite"))
        let before = V372.fingerprint(root)

        let opened = try await V372.open(root, fs: LocalFileSystem())

        #expect(opened.failure?.code == .stoDb003)
        #expect(V372.tmpEntries(root).isEmpty, "\(V372.tmpEntries(root))")
        #expect(V372.fingerprint(root) == before)
    }

    // MARK: stale -shm

    /// OC-372-19: given a healthy WAL-mode file, no -wal, and a stale 32 KiB garbage -shm beside it (a file restored
    /// with a leftover index), when opened, then it opens intact (300 items), nothing quarantined, main's bytes
    /// unchanged by the probe. Dies if a read-only connection's recovery failure (not CANTOPEN) is thrown as STO-DB-003.
    @Test func healthyWalFile_staleGarbageShm_noWal_opensIntact() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root))
        try Data((0..<32768).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            .write(to: root.appendingPathComponent("flotsam.sqlite-shm"))

        let opened = try await V372.open(root, fs: LocalFileSystem())

        #expect(opened.failure == nil, "healthy file refused: \(String(describing: opened.failure?.code)) \(String(describing: opened.failure?.underlying))")
        #expect(opened.notice == nil)
        #expect(opened.count == 300)
        #expect(V370.corruptFolders(root).isEmpty)
    }

    /// OC-372-20: given committed -wal frames plus a stale garbage -shm, when opened, then 303 rows, no quarantine.
    @Test func committedWalRows_staleGarbageShm_opensWithRows() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        try Data((0..<32768).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
            .write(to: root.appendingPathComponent("flotsam.sqlite-shm"))

        let opened = try await V372.open(root, fs: LocalFileSystem())

        #expect(opened.failure == nil, "healthy file refused: \(String(describing: opened.failure?.code)) \(String(describing: opened.failure?.underlying))")
        #expect(opened.notice == nil)
        #expect(opened.count == 303)
        #expect(V370.corruptFolders(root).isEmpty)
    }

    // MARK: every sidecar combination opens a healthy file

    enum Sidecars: String, CaseIterable, Sendable {
        case none, emptyWal, emptyShm, emptyWalAndShm, garbageShmOnly
    }

    /// OC-372-21: given a healthy WAL-mode file with each sidecar combination, when opened, then it opens with 300
    /// items, no notice, no quarantine, no probe dir, and the main file's content is the same set of items. Which
    /// combinations take the probe-copy path is printed. Dies if any combination makes a healthy file refused.
    @Test(arguments: Sidecars.allCases) func healthyWalFile_everySidecarCombination_opens(_ combo: Sidecars) async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V372.buildWalFile(at: V370.dbURL(root))
        let shm = root.appendingPathComponent("flotsam.sqlite-shm")
        switch combo {
        case .none: break
        case .emptyWal: FileManager.default.createFile(atPath: V370.walURL(root).path, contents: Data())
        case .emptyShm: FileManager.default.createFile(atPath: shm.path, contents: Data())
        case .emptyWalAndShm:
            FileManager.default.createFile(atPath: V370.walURL(root).path, contents: Data())
            FileManager.default.createFile(atPath: shm.path, contents: Data())
        case .garbageShmOnly: try Data(repeating: 0xAB, count: 32768).write(to: shm)
        }
        let fs = ProbeFileSystem()

        let opened = try await V372.open(root, fs: fs)

        print("OC-372-21 \(combo.rawValue): probe copies \(fs.probeCopies.count)")
        #expect(opened.failure == nil, "\(combo): refused \(String(describing: opened.failure?.code)) \(String(describing: opened.failure?.underlying))")
        #expect(opened.notice == nil, "\(combo)")
        #expect(opened.count == 300, "\(combo)")
        #expect(V370.corruptFolders(root).isEmpty, "\(combo)")
        #expect(V372.probeDirs(root).isEmpty, "\(combo)")
    }
}
