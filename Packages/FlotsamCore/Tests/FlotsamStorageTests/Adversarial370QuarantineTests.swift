import CryptoKit
import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-370 / FR-007-13, AC-007-11, AC-007-15: adversarial, blind verification of "a damaged database is quarantined
// exactly as found". Written without reading the implementer's tests. Every expected value is a literal (a hash taken
// from the input file before the open, a file name, a count); nothing is recomputed with the production helper.
//
// Fixtures are built with raw GRDB on throwaway folders and verified as damaged by an independent read-only
// `quick_check` on a COPY, so each test proves its arrange actually produced a failing file.

enum V370 {
    static let pageSize = 4096
    enum ArrangeError: Error { case noPage }
    static let oldDate = Date(timeIntervalSince1970: 1_577_836_800)  // 2020-01-01T00:00:00Z

    static func makeRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("v370-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func dbURL(_ root: URL) -> URL { root.appendingPathComponent("flotsam.sqlite") }
    static func walURL(_ root: URL) -> URL { root.appendingPathComponent("flotsam.sqlite-wal") }

    static func sha(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
    }

    static func itemId(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }

    /// A healthy version-`version` Flotsam database: the real v1 schema, `items` item rows and one representation row
    /// each (so the file spans many pages), written through a plain rollback-journal connection.
    static func buildPlain(at url: URL, items: Int, version: Int = 1) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try populate(db, items: items, version: version) }
        try queue.close()
    }

    /// A v0 database: one `legacy` table, `rows` rows of 200 bytes each, user_version 0.
    static func buildLegacy(at url: URL, rows: Int = 1, incrementalVacuum: Bool = false) throws {
        let queue = try DatabaseQueue(path: url.path)
        if incrementalVacuum { try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL") } }
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE legacy (x TEXT)")
            for n in 0..<rows {
                try db.execute(
                    sql: "INSERT INTO legacy VALUES (?)",
                    arguments: [rows == 1 ? "keep-me" : String(repeating: "x", count: 200) + "\(n)"])
            }
        }
        try queue.close()
    }

    static func populate(_ db: Database, items: Int, version: Int) throws {
        try Schema.createVersion1(db)
        for n in 1...max(items, 1) where n <= items {
            try db.execute(
                sql: """
                    INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, updatedAt, plainText)
                    VALUES (?, 'text', 1, 1, ?, 1, ?)
                    """,
                arguments: [itemId(n), String(repeating: "k", count: 120) + "\(n)", "text \(n)"])
            try db.execute(
                sql: "INSERT INTO representation (itemId, uti, byteSize, blobName) VALUES (?, 'public.rtf', 10, ?)",
                arguments: [itemId(n), String(repeating: "b", count: 100) + "\(n)"])
        }
        try db.execute(sql: "INSERT INTO meta(key, value) VALUES ('schemaVersion', '\(version)')")
        try db.execute(sql: "PRAGMA user_version = \(version)")
    }

    /// A database in WAL mode whose `-wal` holds committed frames that were never checkpointed into the main file:
    /// phase 1 writes the base data and closes (checkpoint), phase 2 reopens with autocheckpoint off, commits three
    /// more items, and the files are copied while the pool is still open (as a crash would leave them).
    /// Returns the page numbers the `-wal` carries.
    @discardableResult
    static func buildWithWal(into root: URL) throws -> Set<Int> {
        let staging = makeRoot()
        defer { try? FileManager.default.removeItem(at: staging) }
        let path = staging.appendingPathComponent("flotsam.sqlite").path
        try buildWal(path: path)
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA wal_autocheckpoint = 0") }
        let pool = try DatabasePool(path: path, configuration: configuration)
        try pool.write { db in
            for n in 1001...1003 {
                try db.execute(
                    sql: """
                        INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, updatedAt, plainText)
                        VALUES (?, 'text', 2, 2, ?, 2, 'wal only')
                        """,
                    arguments: [itemId(n), "walkey\(n)"])
            }
        }
        let main = staging.appendingPathComponent("flotsam.sqlite")
        let wal = staging.appendingPathComponent("flotsam.sqlite-wal")
        guard size(wal) > 0 else { throw NSError(domain: "v370", code: 1, userInfo: [NSLocalizedDescriptionKey: "no wal"]) }
        try FileManager.default.copyItem(at: main, to: dbURL(root))
        try FileManager.default.copyItem(at: wal, to: walURL(root))
        let pages = try walPages(walURL(root))
        try pool.close()
        return pages
    }

    static func buildWal(path: String) throws {
        let pool = try DatabasePool(path: path)
        try pool.write { db in try populate(db, items: 300, version: 1) }
        try pool.close()
    }

    /// Page numbers of every frame in a WAL file (frame header: big-endian page number at offset 0).
    static func walPages(_ url: URL) throws -> Set<Int> {
        let data = try Data(contentsOf: url)
        var pages = Set<Int>()
        var offset = 32
        while offset + 24 + pageSize <= data.count {
            let n = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            pages.insert(n)
            offset += 24 + pageSize
        }
        return pages
    }

    /// Overwrites the highest-numbered page that no WAL frame supersedes with 0xFF, leaving the header page alone.
    @discardableResult
    static func damageLatePage(_ url: URL, avoiding walPages: Set<Int> = []) throws -> Int {
        let pageCount = size(url) / pageSize
        guard let page = (2...pageCount).reversed().first(where: { !walPages.contains($0) }) else {
            throw NSError(domain: "v370", code: 2)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64((page - 1) * pageSize))
        try handle.write(contentsOf: Data(repeating: 0xFF, count: pageSize))
        try handle.close()
        return page
    }

    static func pinMtime(_ url: URL, mode: Int = 0o640) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate, .posixPermissions: mode], ofItemAtPath: url.path)
    }

    static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    /// user_version as the raw header says (big-endian 4 bytes at offset 60), independent of SQLite.
    static func headerUserVersion(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url), data.count >= 64 else { return nil }
        return data[60..<64].reduce(0) { ($0 << 8) | Int($1) }
    }

    /// Reads a COPY of a file through a writable connection (a read-only one cannot open a WAL-mode file that has no
    /// -shm/-wal, which would make the oracle itself blind). Only ever pass it a throwaway copy.
    static func readStanding<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read(body)
    }

    enum Verdict: Equatable { case ok, fails }

    /// Independent integrity verdict on a COPY of the file (and its wal), so the input is never touched.
    static func verdict(main: URL, wal: URL? = nil) -> Verdict {
        let scratch = makeRoot()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("c.sqlite")
        try? FileManager.default.copyItem(at: main, to: copy)
        if let wal, FileManager.default.fileExists(atPath: wal.path) {
            try? FileManager.default.copyItem(at: wal, to: scratch.appendingPathComponent("c.sqlite-wal"))
        }
        do {
            let queue = try DatabaseQueue(path: copy.path)  // writable on the throwaway copy: see readStanding
            let rows = try queue.read { try String.fetchAll($0, sql: "PRAGMA quick_check") }
            return rows == ["ok"] ? .ok : .fails
        } catch {
            return .fails
        }
    }

    static func corruptFolders(_ root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("corrupt-") }.sorted()
            .map { root.appendingPathComponent($0, isDirectory: true) }
    }

    static func names(in url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }

    struct Outcome {
        var failure: FlotsamError?
        var notice: FlotsamError?
        var itemCount = -1
        var itemIds = Set<String>()
        var userVersion = -1
        var journalMode = ""
        var tables = Set<String>()
        var quickCheck = [String]()
    }

    /// Opens through the real entry point, inspects the result through the pool, and lets the database go (closing
    /// the pool) before returning, so the caller can look at the files on disk.
    static func open(
        _ root: URL, migrations: [Migration] = Migrations.all, then work: ((FlotsamDatabase) async throws -> Void)? = nil
    ) async throws -> Outcome {
        var outcome = Outcome()
        let result = await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: SystemClock(), migrations: migrations)
        switch result {
        case .failure(let error):
            outcome.failure = error
        case .success(let db):
            outcome.notice = db.openNotice
            try await work?(db)
            let snapshot = try await db.pool.read { conn in
                (
                    try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1,
                    Set(try String.fetchAll(conn, sql: "SELECT id FROM item")),
                    try Int.fetchOne(conn, sql: "PRAGMA user_version") ?? -1,
                    try String.fetchOne(conn, sql: "PRAGMA journal_mode") ?? "",
                    Set(try String.fetchAll(conn, sql: "SELECT name FROM sqlite_master WHERE type='table'")),
                    try String.fetchAll(conn, sql: "PRAGMA quick_check")
                )
            }
            (outcome.itemCount, outcome.itemIds, outcome.userVersion) = (snapshot.0, snapshot.1, snapshot.2)
            (outcome.journalMode, outcome.tables, outcome.quickCheck) = (snapshot.3, snapshot.4, snapshot.5)
        }
        return outcome
    }
}

@Suite("TASK-370 adversarial: quarantine is byte-identical, check runs before any write")
struct Adversarial370QuarantineTests {
    /// Shared assertions for "this input was quarantined as found and a fresh database replaced it".
    private func expectQuarantined(
        root: URL, mainSHA: String, walSHA: String?, outcome: V370.Outcome, sizeBefore: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(outcome.failure == nil, "open must succeed after quarantine", sourceLocation: sourceLocation)
        #expect(outcome.notice?.code == .stoDb002, "STO-DB-002 expected", sourceLocation: sourceLocation)
        let corrupt = V370.corruptFolders(root)
        #expect(corrupt.count == 1, "exactly one corrupt-<ts> folder", sourceLocation: sourceLocation)
        guard let folder = corrupt.first else { return }
        #expect(
            V370.sha(folder.appendingPathComponent("flotsam.sqlite")) == mainSHA,
            "quarantined main file must be byte-identical (sha256) to the input", sourceLocation: sourceLocation)
        #expect(V370.size(folder.appendingPathComponent("flotsam.sqlite")) == sizeBefore, sourceLocation: sourceLocation)
        let wal = folder.appendingPathComponent("flotsam.sqlite-wal")
        if let walSHA {
            #expect(V370.sha(wal) == walSHA, "quarantined -wal must be byte-identical to the input", sourceLocation: sourceLocation)
        } else {
            let walSize = V370.size(wal)
            #expect(walSize <= 0, "no -wal existed, so none (or an empty one) may appear; size \(walSize)", sourceLocation: sourceLocation)
        }
        // The quarantine holds only files Flotsam moves: database, -wal, -shm, blobs.
        #expect(
            V370.names(in: folder).isSubset(of: ["flotsam.sqlite", "flotsam.sqlite-wal", "flotsam.sqlite-shm", "blobs"]),
            "unexpected content in quarantine: \(V370.names(in: folder))", sourceLocation: sourceLocation)
        // Fresh database in place, healthy, empty, version 1.
        #expect(outcome.itemCount == 0, sourceLocation: sourceLocation)
        #expect(outcome.userVersion == 1, sourceLocation: sourceLocation)
        #expect(outcome.quickCheck == ["ok"], sourceLocation: sourceLocation)
        #expect(V370.sha(V370.dbURL(root)) != mainSHA, "the live file must be the new database", sourceLocation: sourceLocation)
    }

    // MARK: damage shapes

    /// OC-370-01: given a valid database whose last page is destroyed (header and user_version intact), no -wal,
    /// when opened, then the file, its mtime and mode are quarantined exactly, blobs move, a fresh database serves.
    /// Dies if the integrity check runs after the pool opens, or the probe is skipped.
    @Test func latePageDamage_noWal_quarantinedByteIdentical_withMtimeModeBlobs() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildPlain(at: V370.dbURL(root), items: 300)
        let page = try V370.damageLatePage(V370.dbURL(root))
        try V370.pinMtime(V370.dbURL(root), mode: 0o640)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try Data("blob-bytes-1".utf8).write(to: root.appendingPathComponent("blobs/aa.bin"))

        // Precondition: header page intact, version 1 in the header, the file really fails quick_check.
        #expect(page >= 3, "damage must be in a late page")
        #expect(V370.headerUserVersion(V370.dbURL(root)) == 1)
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails, "arrange must produce a damaged file")
        #expect(!FileManager.default.fileExists(atPath: V370.walURL(root).path))
        let sha = V370.sha(V370.dbURL(root))!
        let size = V370.size(V370.dbURL(root))

        let t0 = Int64(Date().timeIntervalSince1970 * 1000)
        let outcome = try await V370.open(root)
        let t1 = Int64(Date().timeIntervalSince1970 * 1000)

        expectQuarantined(root: root, mainSHA: sha, walSHA: nil, outcome: outcome, sizeBefore: size)
        let folder = try #require(V370.corruptFolders(root).first)
        let stamp = Int64(folder.lastPathComponent.dropFirst("corrupt-".count))
        #expect(stamp != nil && stamp! >= t0 - 1 && stamp! <= t1 + 1, "timestamp \(String(describing: stamp)) outside [\(t0), \(t1)]")
        // Timestamps and permissions of the quarantined file.
        let moved = folder.appendingPathComponent("flotsam.sqlite")
        #expect(V370.mtime(moved) == V370.oldDate, "a move must not touch mtime; a write would")
        #expect(V370.mode(moved) == 0o640, "mode as found")
        #expect(V370.mode(folder) == 0o700, "the quarantine folder is owner-only")
        #expect(V370.mode(V370.dbURL(root)) == 0o600, "the new database is owner-only (FR-007-01)")
        // Blobs moved intact; the new blobs/ is empty.
        #expect(try Data(contentsOf: folder.appendingPathComponent("blobs/aa.bin")) == Data("blob-bytes-1".utf8))
        #expect(V370.names(in: root.appendingPathComponent("blobs")).isEmpty)
    }

    /// OC-370-02: given committed frames in a non-empty -wal and a destroyed late main-file page that no frame
    /// supersedes, when opened, then BOTH the main file and the -wal are quarantined byte-identical.
    /// Dies if anything (journal-mode change, checkpoint, WAL reset) writes before the move.
    @Test func nonEmptyWal_withDamagedMain_bothFilesByteIdentical() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = try V370.buildWithWal(into: root)
        try V370.damageLatePage(V370.dbURL(root), avoiding: pages)
        try V370.pinMtime(V370.dbURL(root))

        #expect(V370.size(V370.walURL(root)) > 0, "the -wal must carry committed frames")
        #expect(pages.count >= 3)
        #expect(V370.verdict(main: V370.dbURL(root), wal: V370.walURL(root)) == .fails)
        let mainSHA = V370.sha(V370.dbURL(root))!
        let walSHA = V370.sha(V370.walURL(root))!
        let size = V370.size(V370.dbURL(root))

        let outcome = try await V370.open(root)
        expectQuarantined(root: root, mainSHA: mainSHA, walSHA: walSHA, outcome: outcome, sizeBefore: size)
    }

    /// OC-370-03: given a database whose header says WAL mode but whose -wal does not exist, damaged late, when
    /// opened, then the main file is identical and no non-empty -wal is invented. (A read-only open of a WAL-mode file
    /// may create an empty -wal/-shm; an empty one is tolerated, content is not.)
    @Test func walModeHeader_noWalFile_damaged_mainIdentical() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWal(path: V370.dbURL(root).path)
        try? FileManager.default.removeItem(at: V370.walURL(root))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("flotsam.sqlite-shm"))
        try V370.damageLatePage(V370.dbURL(root))
        try V370.pinMtime(V370.dbURL(root))
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails)
        let sha = V370.sha(V370.dbURL(root))!
        let size = V370.size(V370.dbURL(root))

        let outcome = try await V370.open(root)
        expectQuarantined(root: root, mainSHA: sha, walSHA: nil, outcome: outcome, sizeBefore: size)
    }

    /// OC-370-04: given a file cut to two whole pages (header intact, the rest of the tree gone), when opened, then
    /// quarantined byte-identical.
    @Test func truncatedAtPageBoundary_quarantinedIdentical() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildPlain(at: V370.dbURL(root), items: 300)
        try FileHandle(forWritingTo: V370.dbURL(root)).truncate(atOffset: UInt64(2 * V370.pageSize))
        try V370.pinMtime(V370.dbURL(root))
        #expect(V370.size(V370.dbURL(root)) == 8192)
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails)
        let sha = V370.sha(V370.dbURL(root))!

        let outcome = try await V370.open(root)
        expectQuarantined(root: root, mainSHA: sha, walSHA: nil, outcome: outcome, sizeBefore: 8192)
    }

    /// OC-370-05: given a file cut in the middle of a page, when opened, then quarantined byte-identical.
    @Test func truncatedMidPage_quarantinedIdentical() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildPlain(at: V370.dbURL(root), items: 300)
        let cut = 20 * V370.pageSize + 1234
        try FileHandle(forWritingTo: V370.dbURL(root)).truncate(atOffset: UInt64(cut))
        try V370.pinMtime(V370.dbURL(root))
        #expect(V370.size(V370.dbURL(root)) == cut)
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails)
        let sha = V370.sha(V370.dbURL(root))!

        let outcome = try await V370.open(root)
        expectQuarantined(root: root, mainSHA: sha, walSHA: nil, outcome: outcome, sizeBefore: cut)
    }

    /// OC-370-06: given 100 KB of random bytes (the AC-007-11 shape), when opened, then quarantined byte-identical.
    @Test func notSQLite_randomBytes_quarantinedIdentical() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<102_400).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try bytes.write(to: V370.dbURL(root))
        try V370.pinMtime(V370.dbURL(root))
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails)
        let sha = V370.sha(V370.dbURL(root))!

        let outcome = try await V370.open(root)
        expectQuarantined(root: root, mainSHA: sha, walSHA: nil, outcome: outcome, sizeBefore: 102_400)
    }

    /// OC-370-07: given a 5-byte text file named flotsam.sqlite (smaller than a SQLite header), when opened, then it
    /// is quarantined byte-identical, not silently adopted and overwritten as an empty database.
    @Test func tinyNonSQLiteFile_isNotOverwritten() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: V370.dbURL(root))
        try V370.pinMtime(V370.dbURL(root))
        let sha = V370.sha(V370.dbURL(root))!

        let outcome = try await V370.open(root)
        // The user's 5 bytes must survive somewhere, byte for byte, whatever the open decided.
        let preserved = V370.corruptFolders(root).contains {
            V370.sha($0.appendingPathComponent("flotsam.sqlite")) == sha
        } || V370.sha(V370.dbURL(root)) == sha
        #expect(preserved, "the 5 original bytes were destroyed (outcome notice: \(String(describing: outcome.notice?.code)))")
        #expect(V370.corruptFolders(root).count == 1, "a non-database file is a quarantine case")
        expectQuarantined(root: root, mainSHA: sha, walSHA: nil, outcome: outcome, sizeBefore: 5)
    }

    /// OC-370-08: given a zero-byte flotsam.sqlite, when opened, then it is an empty database to SQLite: it opens,
    /// migrates to 1, nothing is quarantined, no STO-DB-002 and no pre-migration copy of an empty file.
    @Test func zeroByteFile_opensFresh_noQuarantine() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: V370.dbURL(root))
        #expect(V370.size(V370.dbURL(root)) == 0)

        let outcome = try await V370.open(root)
        #expect(outcome.failure == nil)
        #expect(outcome.notice == nil)
        #expect(V370.corruptFolders(root).isEmpty)
        #expect(outcome.userVersion == 1)
        #expect(outcome.quickCheck == ["ok"])
        let preMigration = V370.names(in: root.appendingPathComponent("pre-migration"))
        #expect(preMigration.isEmpty, "an empty file is not a database worth a backup: \(preMigration)")
    }

    // MARK: user_version interplay

    /// OC-370-09: given a v0 database (legacy table, user_version 0, healthy), when opened, then it migrates to 1,
    /// pre-migration/flotsam-v0.sqlite exists, the legacy row survives and nothing is quarantined.
    /// Dies if the checks quarantine a healthy file or the migration path is skipped.
    @Test func healthyV0_migrates_noQuarantine_backupMade() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildLegacy(at: V370.dbURL(root))
        #expect(V370.headerUserVersion(V370.dbURL(root)) == 0)

        var legacyRows = [String]()
        let outcome = try await V370.open(root) { db in
            legacyRows = try await db.pool.read { try String.fetchAll($0, sql: "SELECT x FROM legacy") }
        }
        #expect(outcome.failure == nil)
        #expect(outcome.notice == nil)
        #expect(outcome.userVersion == 1)
        #expect(outcome.tables.isSuperset(of: ["item", "representation", "meta", "legacy"]))
        #expect(legacyRows == ["keep-me"])
        #expect(outcome.quickCheck == ["ok"])
        #expect(V370.corruptFolders(root).isEmpty)
        #expect(V370.names(in: root.appendingPathComponent("pre-migration")).contains("flotsam-v0.sqlite"))
    }

    /// OC-370-10: given a v0 file damaged in a late page, when opened, then it is quarantined identical, NOT
    /// migrated, and no pre-migration copy of the damaged bytes is made.
    @Test func damagedV0_quarantinedBeforeMigration_noBackup() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildLegacy(at: V370.dbURL(root), rows: 2000)
        try V370.damageLatePage(V370.dbURL(root))
        try V370.pinMtime(V370.dbURL(root))
        #expect(V370.headerUserVersion(V370.dbURL(root)) == 0)
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails)
        let sha = V370.sha(V370.dbURL(root))!
        let size = V370.size(V370.dbURL(root))

        let outcome = try await V370.open(root)
        expectQuarantined(root: root, mainSHA: sha, walSHA: nil, outcome: outcome, sizeBefore: size)
        #expect(V370.names(in: root.appendingPathComponent("pre-migration")).isEmpty, "no backup of a damaged file")
    }

    /// OC-370-11: given a healthy file at user_version 99, when opened, then STO-DB-003, the file is byte-identical
    /// and nothing is quarantined (AC-007-15). Dies if the newer-version guard moves behind a write.
    @Test func healthyNewerVersion_refused_untouched() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildPlain(at: V370.dbURL(root), items: 5, version: 99)
        try V370.pinMtime(V370.dbURL(root))
        let sha = V370.sha(V370.dbURL(root))!

        let outcome = try await V370.open(root)
        #expect(outcome.failure?.code == .stoDb003)
        #expect(outcome.notice == nil)
        #expect(V370.sha(V370.dbURL(root)) == sha, "refusing a newer database must not modify it")
        #expect(V370.mtime(V370.dbURL(root)) == V370.oldDate)
        #expect(V370.corruptFolders(root).isEmpty)
    }

    /// OC-370-12: given a DAMAGED file that claims user_version 99 in its header, when opened, then integrity wins:
    /// it is quarantined (the version of a damaged file is not trusted), byte-identical.
    @Test func damagedFileClaimingNewerVersion_quarantinedNotRefused() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildPlain(at: V370.dbURL(root), items: 300, version: 99)
        try V370.damageLatePage(V370.dbURL(root))
        try V370.pinMtime(V370.dbURL(root))
        #expect(V370.headerUserVersion(V370.dbURL(root)) == 99)
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails)
        let sha = V370.sha(V370.dbURL(root))!
        let size = V370.size(V370.dbURL(root))

        let outcome = try await V370.open(root)
        expectQuarantined(root: root, mainSHA: sha, walSHA: nil, outcome: outcome, sizeBefore: size)
    }

    // MARK: healthy files

    /// OC-370-13: given a healthy v1 database with 300 items (rollback journal), when opened, then it opens, every
    /// item id is present, no quarantine, no notice. Dies if a false-positive check quarantines good data.
    @Test func healthyDatabase_opensIntact_notQuarantined() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildPlain(at: V370.dbURL(root), items: 300)
        #expect(V370.verdict(main: V370.dbURL(root)) == .ok)

        let outcome = try await V370.open(root)
        #expect(outcome.failure == nil)
        #expect(outcome.notice == nil)
        #expect(V370.corruptFolders(root).isEmpty)
        #expect(outcome.itemCount == 300)
        #expect(outcome.itemIds.contains(V370.itemId(1)) && outcome.itemIds.contains(V370.itemId(300)))
        #expect(outcome.userVersion == 1)
        #expect(outcome.journalMode == "wal")
        #expect(outcome.quickCheck == ["ok"])
    }

    /// OC-370-14: given a healthy database whose three newest items live only in the -wal, when opened, then the WAL
    /// is replayed (303 items incl. the three) and nothing is quarantined. Dies if a check ignores the -wal or the
    /// recovery path treats unchecked frames as damage.
    @Test func healthyWithCommittedWalFrames_replayed_notQuarantined() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        #expect(V370.size(V370.walURL(root)) > 0)
        #expect(V370.verdict(main: V370.dbURL(root), wal: V370.walURL(root)) == .ok)

        let outcome = try await V370.open(root)
        #expect(outcome.failure == nil)
        #expect(outcome.notice == nil)
        #expect(V370.corruptFolders(root).isEmpty)
        #expect(outcome.itemCount == 303)
        #expect(outcome.itemIds.isSuperset(of: [V370.itemId(1001), V370.itemId(1002), V370.itemId(1003)]))
    }

    // MARK: after quarantine

    /// OC-370-15: given a damaged file quarantined on the first open, a row written to the fresh database, and the
    /// app relaunched, then the second open succeeds with no notice, no second corrupt folder, the row persisted
    /// (fresh instance), and the first quarantine untouched.
    @Test func repeatedOpenAfterQuarantine_getsFreshDatabase_noSecondQuarantine() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildPlain(at: V370.dbURL(root), items: 300)
        try V370.damageLatePage(V370.dbURL(root))
        try V370.pinMtime(V370.dbURL(root))
        let sha = V370.sha(V370.dbURL(root))!

        let first = try await V370.open(root) { db in
            try await db.pool.write { conn in
                try conn.execute(
                    sql: "INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, updatedAt) VALUES (?, 'text', 1, 1, 'k', 1)",
                    arguments: [V370.itemId(42)])
            }
        }
        #expect(first.notice?.code == .stoDb002)
        #expect(first.itemCount == 1)
        let folder = try #require(V370.corruptFolders(root).first)

        let second = try await V370.open(root)
        #expect(second.failure == nil)
        #expect(second.notice == nil, "a healthy relaunch must not raise STO-DB-002 again")
        #expect(V370.corruptFolders(root) == [folder], "no second quarantine folder")
        #expect(second.itemIds == [V370.itemId(42)], "the row written after quarantine must survive the relaunch")
        #expect(V370.sha(folder.appendingPathComponent("flotsam.sqlite")) == sha, "first quarantine untouched")
    }

    /// OC-370-18: given a HEALTHY database in WAL mode (as every Flotsam database is) whose -wal and -shm are absent
    /// (a restore or copy of the main file alone, or a sidecar cleaned up by another tool), when opened, then it opens
    /// as before: nothing was damaged, so nothing may be refused or quarantined. Dies if the read-only probe cannot
    /// open a sidecar-less WAL file and the open is reported as a failure.
    @Test func healthyWalDatabase_withoutSidecars_opensIntact() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWal(path: V370.dbURL(root).path)
        try? FileManager.default.removeItem(at: V370.walURL(root))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("flotsam.sqlite-shm"))
        #expect(V370.verdict(main: V370.dbURL(root)) == .ok, "arrange: the file is healthy")
        #expect(V370.headerUserVersion(V370.dbURL(root)) == 1)

        let outcome = try await V370.open(root)

        #expect(outcome.failure == nil, "healthy file refused: \(String(describing: outcome.failure?.code)) \(String(describing: outcome.failure?.underlying))")
        #expect(outcome.notice == nil)
        #expect(outcome.itemCount == 300)
        #expect(V370.corruptFolders(root).isEmpty, "a healthy file is never quarantined")
    }

    // MARK: the post-migration check

    /// A migration that leaves structural damage the open's own connections cannot notice until quick_check runs: it
    /// overwrites the LAST page of the main file (a page the migration never touches and that is not in the -wal) with
    /// 0xFF, behind SQLite's back. Fires only in a file holding the `legacy` marker table; the fresh database of the
    /// second attempt is left alone. (A CHECK-violating row is NOT usable here: quick_check on a read-only connection,
    /// which is what both the probe and `pool.read` are, does not verify CHECK constraints. See the report.)
    private static func sabotage(root: URL) -> Migration {
        let main = V370.dbURL(root)
        return Migration(version: 2) { db in
            let hasLegacy = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'legacy'") == 1
            guard hasLegacy else { return }
            let handle = try FileHandle(forUpdating: main)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end - 4096)
            try handle.write(contentsOf: Data(repeating: 0xFF, count: 4096))
            try handle.synchronize()
        }
    }

    /// The second kind of post-migration failure: quick_check RETURNS failing rows ("free space corruption") instead
    /// of throwing. The migration sets the first-freeblock pointer of one leaf table page to 0xFFF0 behind SQLite's
    /// back. The page is the highest leaf (type byte 0x0D) that no WAL frame supersedes, so readers see the edit.
    /// Same marker rule as `sabotage(root:)`. (Measured in a scratch run: this damage returns rows, a 0xFF-filled
    /// page throws SQLITE_CORRUPT.)
    private static func rowsSabotage(root: URL) -> Migration {
        let main = V370.dbURL(root)
        return Migration(version: 2) { db in
            let hasLegacy = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'legacy'") == 1
            guard hasLegacy else { return }
            let superseded = try V370.walPages(URL(fileURLWithPath: main.path + "-wal"))
            let handle = try FileHandle(forUpdating: main)
            defer { try? handle.close() }
            let pages = Int(try handle.seekToEnd()) / V370.pageSize
            for page in stride(from: pages, through: 2, by: -1) where !superseded.contains(page) {
                try handle.seek(toOffset: UInt64((page - 1) * V370.pageSize))
                guard try handle.read(upToCount: 1)?.first == 0x0D else { continue }
                try handle.seek(toOffset: UInt64((page - 1) * V370.pageSize + 1))
                try handle.write(contentsOf: Data([0xFF, 0xF0]))
                try handle.synchronize()
                return
            }
            throw V370.ArrangeError.noPage
        }
    }

    /// OC-370-16: given a healthy v0 file (auto_vacuum already incremental, ~25 legacy pages) and a migration that
    /// corrupts the main file's last page, when opened, then the post-migration check sends it down the damaged path:
    /// STO-DB-002, one corrupt folder holding the migrated main file (version 2, schema present, failing quick_check;
    /// the pool was closed and checkpointed before the move so it is self-contained), and a fresh healthy database.
    /// Dies if the post-migration check is skipped, or if the quarantine moves files while the pool is still open.
    @Test func postMigrationCheckFailure_throwingCheck_takesDamagedPath_selfContainedQuarantine() async throws {
        try await postMigrationScenario { [Migrations.all[0], Self.sabotage(root: $0)] }
    }

    /// OC-370-16b: same obligations when the post-migration quick_check returns failing rows instead of throwing.
    /// Dies if a non-"ok" result is ignored (`.damaged` branch replaced by `.opened`).
    @Test func postMigrationCheckFailure_rowsCheck_takesDamagedPath_selfContainedQuarantine() async throws {
        try await postMigrationScenario { [Migrations.all[0], Self.rowsSabotage(root: $0)] }
    }

    private func postMigrationScenario(_ migrationsFor: (URL) -> [Migration]) async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildLegacy(at: V370.dbURL(root), rows: 400, incrementalVacuum: true)
        #expect(V370.size(V370.dbURL(root)) >= 20 * 4096, "arrange: the legacy table must span many pages")
        let migrations = migrationsFor(root)

        let outcome = try await V370.open(root, migrations: migrations)

        #expect(outcome.failure == nil, "second attempt on a fresh file must succeed: \(String(describing: outcome.failure?.code))")
        #expect(outcome.notice?.code == .stoDb002)
        let corrupt = V370.corruptFolders(root)
        #expect(corrupt.count == 1)
        let folder = try #require(corrupt.first)
        // The live database is the fresh one: version 2, no legacy table, healthy.
        #expect(outcome.userVersion == 2)
        #expect(!outcome.tables.contains("legacy"))
        #expect(outcome.itemCount == 0)
        #expect(outcome.quickCheck == ["ok"])
        // The quarantined file stands alone (copy ONLY the main file elsewhere): it is the sabotaged migrated file.
        let quarantinedMain = folder.appendingPathComponent("flotsam.sqlite")
        #expect(V370.headerUserVersion(quarantinedMain) == 2, "migrations were checkpointed into the main file before the move")
        let alone = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: alone) }
        let aloneDB = alone.appendingPathComponent("q.sqlite")
        try FileManager.default.copyItem(at: quarantinedMain, to: aloneDB)
        let tables = try V370.readStanding(aloneDB) { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
        }
        #expect(tables.isSuperset(of: ["item", "meta"]), "the migrated schema is in the main file without its -wal")
        #expect(V370.verdict(main: aloneDB) == .fails, "the quarantined file is the one that failed the check")
        #expect(!V370.names(in: root).contains("flotsam.sqlite-wal-old"))
    }

    /// OC-370-17: given the same sabotage but with the migration that does NOT damage (no legacy marker), when
    /// opened, then the same code path passes and nothing is quarantined: the post-migration check has no
    /// false positive on a healthy migrated file.
    @Test func postMigrationCheck_healthyMigratedFile_passes() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildPlain(at: V370.dbURL(root), items: 10, version: 1)
        let migrations = [Migrations.all[0], Self.sabotage(root: root)]  // v1 file has no `legacy` table: sabotage is a no-op

        let outcome = try await V370.open(root, migrations: migrations)
        #expect(outcome.failure == nil)
        #expect(outcome.notice == nil)
        #expect(V370.corruptFolders(root).isEmpty)
        #expect(outcome.userVersion == 2)
        #expect(outcome.itemCount == 10)
    }
}
