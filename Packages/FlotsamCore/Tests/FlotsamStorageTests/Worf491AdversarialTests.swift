import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-491 QA (Worf, blind). Adversarial proof for the ADR-0011 `postMigrationCheck` seam and the FR-007-17 future-dated
// copy rule (AC-007-18). Expected values are literals; the arrangement reads and writes the disk directly. Each test
// names the code change that turns it red.
//
// Mutations these are written to kill (all run by hand against FlotsamDatabase.swift / PlaintextCopies.swift):
//   M-A drop the `passed` result (`passed ? .opened : .damaged` becomes `.opened`)
//   M-B the seam also replaces the pre-open probe's integrity check
//   M-C the launch cleanup (expirePlaintextCopies) runs before the post-migration check
//   M-D nil seam stops running the real check (`?? integrityCheckPasses` becomes `?? { _ in true }`)
//   M-E the check runs before the migrations rather than after

@Suite struct Worf491AdversarialTests {
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private var v2: Migration { Migration(version: 2) { db in try db.execute(sql: "CREATE TABLE probe (id INTEGER)") } }

    /// Records every call and the schema version the connection reported; fails the first `failFirst` calls.
    private final class Seam: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var versions: [Int] = []
        private let failFirst: Int
        init(failFirst: Int) { self.failFirst = failFirst }
        var callCount: Int { lock.withLock { calls } }
        var seenVersions: [Int] { lock.withLock { versions } }
        func check(_ db: Database) throws -> Bool {
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
            return lock.withLock {
                calls += 1
                versions.append(version)
                return calls > failFirst
            }
        }
    }

    private func corruptFolders(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("corrupt-") }.sorted()
    }

    private func names(_ dir: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    private func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    /// A root holding a v2 database (migrated from v1 by a real launch) and the pre-migration copy that launch left.
    private func migratedRoot(clock: ManualClock) async throws -> (root: URL, copy: URL, migrations: [Migration]) {
        let first = try await Store.make(clock: clock)
        let migrations = Migrations.all + [v2]
        _ = try await FlotsamDatabase.open(
            folder: first.root, fileSystem: LocalFileSystem(), clock: clock, migrations: migrations).get()
        let copy = first.root.appendingPathComponent("pre-migration/\(DataFolder.preMigrationCopyName(fromVersion: 1))")
        #expect(exists(copy), "arrange: the migrating launch took a copy")
        #expect(corruptFolders(first.root).isEmpty, "arrange: nothing is quarantined yet")
        return (first.root, copy, migrations)
    }

    // MARK: failing check on a confirming launch

    /// OC-491-W01. Given a confirming launch (no migration runs) whose post-migration check fails on EVERY attempt, when
    /// it opens, then it fails closed with STO-DB-003, exactly one quarantine holds the database, and the copy, a
    /// sidecar and a foreign file in `pre-migration/` are all still there byte for byte. Red under M-A (the open would
    /// succeed and the confirming launch would delete the copy) and under M-C (the copy is gone before the check).
    @Test func aCheckThatKeepsFailingOnAConfirmingLaunchFailsClosedAndDeletesNothing() async throws {
        let clock = ManualClock()
        let (root, copy, migrations) = try await migratedRoot(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let sidecar = root.appendingPathComponent("pre-migration/flotsam-v1.sqlite-wal")
        try Data("wal-bytes".utf8).write(to: sidecar)
        let foreign = root.appendingPathComponent("pre-migration/notes.txt")
        try Data("foreign".utf8).write(to: foreign)
        let copyBefore = try #require(bytes(copy))
        let namesBefore = names(root.appendingPathComponent("pre-migration"))
        #expect(namesBefore == ["flotsam-v1.sqlite", "flotsam-v1.sqlite-wal", "notes.txt"])
        clock.advance(ms: hourMs)
        let seam = Seam(failFirst: 99)

        let result = await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: clock, migrations: migrations,
            postMigrationCheck: seam.check)

        guard case .failure(let error) = result else { Issue.record("a check that always fails must not open"); return }
        #expect(error.code == .stoDb003)
        #expect(seam.callCount == 2, "once on the migrated file, once on the fresh file of the second attempt")
        let corrupt = corruptFolders(root)
        #expect(corrupt.count == 1)
        let quarantined = try #require(corrupt.first)
        #expect(exists(root.appendingPathComponent(quarantined).appendingPathComponent("flotsam.sqlite")), "the database was moved into the quarantine")
        #expect(names(root.appendingPathComponent("pre-migration")) == namesBefore, "nothing in pre-migration/ was added or removed")
        #expect(bytes(copy) == copyBefore, "the copy is byte-identical")
        #expect(bytes(sidecar) == Data("wal-bytes".utf8))
        #expect(bytes(foreign) == Data("foreign".utf8))
    }

    /// OC-491-W02. Given the launch that MIGRATES (v1 to v2) and a post-migration check that fails, when it opens, then
    /// it quarantines, raises STO-DB-002, and the copy it just took is still there. Red under M-C-like orderings that
    /// delete on this path, and under dropping the copy.
    @Test func aFailingCheckOnTheMigratingLaunchQuarantinesAndKeepsTheCopy() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let migrations = Migrations.all + [v2]
        let seam = Seam(failFirst: 1)

        let db = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: clock, migrations: migrations,
            postMigrationCheck: seam.check).get()

        #expect(db.openNotice?.code == .stoDb002)
        #expect(corruptFolders(root).count == 1)
        #expect(names(root.appendingPathComponent("pre-migration")) == ["flotsam-v1.sqlite"])
        #expect(seam.seenVersions == [2, 2], "migrated file first, then the fresh file migrated to the same newest version")
    }

    /// OC-491-W03. Given a confirming launch and a passing seam, when it opens, then the check ran exactly once, after
    /// the migrations (the connection reports the newest schema version, 2), and the copy is gone. Red under M-E (the
    /// check would run on version 1) and M-A is irrelevant here (the control for W01).
    @Test func theCheckRunsOnceAfterMigrationAndAPassingOneConfirms() async throws {
        let clock = ManualClock()
        let (root, copy, migrations) = try await migratedRoot(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        clock.advance(ms: 60_000)
        let seam = Seam(failFirst: 0)

        let db = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: clock, migrations: migrations,
            postMigrationCheck: seam.check).get()

        #expect(db.openNotice == nil)
        #expect(seam.callCount == 1)
        #expect(seam.seenVersions == [2])
        #expect(!exists(copy))
        #expect(names(root.appendingPathComponent("pre-migration")).isEmpty)
        #expect(corruptFolders(root).isEmpty)
    }

    // MARK: the seam never replaces the pre-open probe

    /// A v1 file whose free-space pointer on one leaf page is broken: `quick_check` RETURNS failing rows on it (it does
    /// not throw), so only a real integrity check, not an error path, can reject it.
    private func damagedPlainDatabase(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let main = V370.dbURL(root)
        try V370.buildPlain(at: main, items: 300)
        let handle = try FileHandle(forUpdating: main)
        defer { try? handle.close() }
        let pages = Int(try handle.seekToEnd()) / V370.pageSize
        var damaged = false
        for page in stride(from: pages, through: 2, by: -1) {
            try handle.seek(toOffset: UInt64((page - 1) * V370.pageSize))
            guard try handle.read(upToCount: 1)?.first == 0x0D else { continue }
            try handle.seek(toOffset: UInt64((page - 1) * V370.pageSize + 1))
            try handle.write(contentsOf: Data([0xFF, 0xF0]))
            try handle.synchronize()
            damaged = true
            break
        }
        try #require(damaged ? () : nil as Void?)
    }

    /// OC-491-W04. Given a file that is really damaged before the open and a seam that always says "healthy", when it
    /// opens, then the pre-open probe still quarantines it (STO-DB-002), the quarantined bytes are the untouched
    /// original, and the seam is consulted only for the fresh file of the second attempt. Red under M-B (the seam would
    /// vouch for the damaged file, which would then open).
    @Test func aHealthySeamCannotVouchForAFileTheProbeRejects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worf491-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try damagedPlainDatabase(at: root)
        #expect(V370.verdict(main: V370.dbURL(root)) == .fails, "arrange: the file really fails quick_check")
        let originalBytes = try #require(bytes(V370.dbURL(root)))
        let seam = Seam(failFirst: 0)

        let db = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: ManualClock(), migrations: Migrations.all,
            postMigrationCheck: seam.check).get()

        #expect(db.openNotice?.code == .stoDb002)
        let corrupt = corruptFolders(root)
        #expect(corrupt.count == 1)
        let quarantined = try #require(corrupt.first)
        #expect(bytes(root.appendingPathComponent(quarantined).appendingPathComponent("flotsam.sqlite")) == originalBytes,
                "the damaged file was set aside untouched")
        #expect(seam.callCount == 1, "only the fresh file reached the post-migration check")
        let items = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") }
        #expect(items == 0, "the live database is the fresh one, not the damaged 300-row file")
    }

    /// OC-491-W05. The same damaged file with the production default (nil seam): identical outcome, so nil is the real
    /// path and the probe is the same under both. Red if nil stops quarantining.
    @Test func theProductionDefaultQuarantinesTheSameDamagedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worf491-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try damagedPlainDatabase(at: root)

        let db = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: ManualClock(), migrations: Migrations.all,
            postMigrationCheck: nil).get()

        #expect(db.openNotice?.code == .stoDb002)
        #expect(corruptFolders(root).count == 1)
        let items = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") }
        #expect(items == 0)
    }

    /// OC-491-W06. Given a healthy migrated database and the nil seam, when a confirming launch opens, then it opens
    /// clean, nothing is quarantined and the copy is deleted: nil does not make healthy files fail and does not skip the
    /// confirmation. Red under M-D only if it also broke a healthy open; it pins that nil is not "always fail".
    @Test func nilSeamOnAHealthyConfirmingLaunchConfirmsAndDeletes() async throws {
        let clock = ManualClock()
        let (root, copy, migrations) = try await migratedRoot(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        clock.advance(ms: 1)

        let db = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: clock, migrations: migrations,
            postMigrationCheck: nil).get()

        #expect(db.openNotice == nil)
        #expect(corruptFolders(root).isEmpty)
        #expect(!exists(copy))
    }

    // MARK: FR-007-17 future-dated copy sentence

    private func setDate(_ url: URL, millis: Int64) throws {
        let when = Date(timeIntervalSince1970: Double(millis) / 1000)
        try FileManager.default.setAttributes([.creationDate: when, .modificationDate: when], ofItemAtPath: url.path)
    }

    /// Plants a copy dated `copyMillis` and a quarantine stamped `stampMillis`, runs a confirming launch, and returns
    /// (copy survived, quarantine survived).
    private func confirmingLaunch(copyMillis: (Int64) -> Int64, stampMillis: (Int64) -> Int64) async throws -> (copy: Bool, quarantine: Bool) {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let now = first.clock.millis
        let copy = try first.plant("pre-migration/flotsam-v1.sqlite")
        try setDate(copy, millis: copyMillis(now))
        let quarantine = try first.plant("corrupt-\(stampMillis(now))/keep.txt").deletingLastPathComponent()
        _ = try await Store.make(root: root, clock: clock)
        return (exists(copy), exists(quarantine))
    }

    /// OC-491-W07. FRD-007 FR-007-17: a copy dated in the future is deleted by a confirming launch even though a young
    /// quarantine really came after it, and the quarantine itself (an hour old, well inside 30 days) survives. Red if
    /// the copy's date stops being the judge (for instance the quarantine rule is changed to compare against `now`),
    /// or if the launch deletes the quarantine.
    @Test func aFutureDatedCopyIsDeletedDespiteARealLaterQuarantine() async throws {
        let outcome = try await confirmingLaunch(copyMillis: { $0 + 400 * dayMs }, stampMillis: { $0 - hourMs })
        #expect(outcome.copy == false)
        #expect(outcome.quarantine == true)
    }

    /// OC-491-W08. The baseline the sentence is an exception to: a copy dated before a quarantine stays, the quarantine
    /// stays. Red if the quarantine-newer-than-copy hold is dropped.
    @Test func aCopyDatedBeforeAQuarantineIsKept() async throws {
        let outcome = try await confirmingLaunch(copyMillis: { $0 - 2 * dayMs }, stampMillis: { $0 - hourMs })
        #expect(outcome.copy == true)
        #expect(outcome.quarantine == true)
    }

    /// OC-491-W09. Boundary: a copy dated exactly at the quarantine's stamp is kept (the quarantine is not older), one
    /// millisecond later it is deleted. Red if the comparison flips to `>=` or `<`.
    @Test func theCopyDateBoundaryIsOneMillisecond() async throws {
        let stamp: Int64 = 1_900_000_000_000  // far-future literal stamp, below Int64 and not expired by a clock at "now"
        let equal = try await confirmingLaunch(copyMillis: { _ in stamp }, stampMillis: { _ in stamp })
        let later = try await confirmingLaunch(copyMillis: { _ in stamp + 1 }, stampMillis: { _ in stamp })
        #expect(equal.copy == true, "dated exactly at the stamp: not newer, kept")
        #expect(later.copy == false, "dated 1 ms after the stamp: newer, deleted")
        #expect(equal.quarantine && later.quarantine)
    }

    /// OC-491-W10. A copy whose creation time is in the future and whose modification time is old is judged by the newer
    /// of the two (FRD wording), so it is deleted; with both old and a young quarantine it is kept (W08 shape).
    @Test func theNewerOfCreationAndModificationDecides() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let now = first.clock.millis
        let copy = try first.plant("pre-migration/flotsam-v1.sqlite")
        // Two calls, in this order: the file system pulls a creation time back to an earlier modification time set after it.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(now - 5 * dayMs) / 1000)], ofItemAtPath: copy.path)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: Double(now + 400 * dayMs) / 1000)], ofItemAtPath: copy.path)
        let attrs = try FileManager.default.attributesOfItem(atPath: copy.path)
        #expect((attrs[.creationDate] as? Date)! > Date().addingTimeInterval(300 * 86_400), "arrange: creation is in the future")
        #expect((attrs[.modificationDate] as? Date)! < Date(), "arrange: modification is in the past")
        let quarantine = try first.plant("corrupt-\(now - hourMs)/keep.txt")

        _ = try await Store.make(root: root, clock: clock)

        #expect(!exists(copy))
        #expect(exists(quarantine))
    }

    // MARK: nil is the real check

    /// A v0 file with a `legacy` table whose migration to v2 overwrites the file's last page with 0xFF behind SQLite's
    /// back, so only the post-migration `quick_check` can see the damage (the probe ran before the migration).
    private func sabotagingMigration(main: URL) -> Migration {
        Migration(version: 2) { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'legacy'") == 1 else { return }
            let handle = try FileHandle(forUpdating: main)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end - 4096)
            try handle.write(contentsOf: Data(repeating: 0xFF, count: 4096))
            try handle.synchronize()
        }
    }

    /// OC-491-W11. Given a migration that damages the file after the probe passed, when the open runs with the nil seam
    /// (production), then the real post-migration `quick_check` quarantines it (STO-DB-002, one folder, the live file is
    /// the fresh empty one). With the seam forced to "healthy" the same file opens damaged: the contrast shows the check
    /// that fired was the default one. Red under M-D (nil no longer runs the real check).
    @Test func theNilSeamRunsTheRealCheckAndCatchesPostMigrationDamage() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildLegacy(at: V370.dbURL(root), rows: 400, incrementalVacuum: true)
        let migrations = [Migrations.all[0], sabotagingMigration(main: V370.dbURL(root))]

        let db = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: ManualClock(), migrations: migrations,
            postMigrationCheck: nil).get()

        #expect(db.openNotice?.code == .stoDb002)
        #expect(corruptFolders(root).count == 1)
        let tables = try await db.pool.read { Set(try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table'")) }
        #expect(!tables.contains("legacy"), "the live database is the fresh one")
    }
}
