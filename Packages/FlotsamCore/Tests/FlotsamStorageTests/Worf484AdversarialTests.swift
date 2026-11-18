import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-484 / FRD-007 FR-007-17, AC-007-18 / audit F-01. Blind adversarial checks of "delete the pre-migration copy once
// a later launch confirms the migration". Every expected value is a literal; the clock is the ManualClock, failures
// come from FaultyFileSystem, and what survived is read from the disk, not from the code under test.
//
// Mutations these are written to kill (each one named in the test that owns it):
//   M1 drop the schema-version check (`migratedThisLaunch` never true)          -> OC-484-01, -02, -03
//   M2 drop the integrity check (`integrityCheckPasses` always true)            -> OC-484-04
//   M3 invert the newer-quarantine guard                                         -> OC-484-06, -07
//   M4 remove the -wal/-shm deletion (names no longer recognised as copies)     -> OC-484-08

@Suite("Worf484: pre-migration copy deleted on confirmation", .timeLimit(.minutes(3)))
struct Worf484AdversarialTests {
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private var v2: Migration { Migration(version: 2) { db in try db.execute(sql: "CREATE TABLE probe (id INTEGER)") } }

    private func open(
        _ root: URL, _ clock: ManualClock, _ migrations: [Migration], fs: any FileSystemPort = LocalFileSystem()
    ) async -> FlotsamResult<FlotsamDatabase> {
        await FlotsamDatabase.open(folder: root, fileSystem: fs, clock: clock, migrations: migrations)
    }

    /// A file in `pre-migration/` whose creation and modification dates are `date`.
    @discardableResult
    private func plantCopy(_ root: URL, _ name: String, at date: Date) throws -> URL {
        let url = root.appendingPathComponent("pre-migration/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plaintext-\(name)".utf8).write(to: url)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    private func plantQuarantine(_ root: URL, stamp: Int64) throws -> URL {
        let folder = root.appendingPathComponent("corrupt-\(stamp)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("plaintext-corrupt".utf8).write(to: folder.appendingPathComponent("flotsam.sqlite"))
        return folder
    }

    private func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// A data folder whose database sits at version 1 (this build's shipped schema), with `rows` items, closed.
    private func makeFolder(clock: ManualClock, rows: Int = 0) async throws -> URL {
        let store = try await Store.make(clock: clock)
        if rows > 0 { try await store.insert((1...rows).map { Spec(n: $0, text: String(repeating: "secret-\($0) ", count: 40)) }) }
        return store.root
    }

    /// Entries of `pre-migration/`, read fresh from the disk.
    private func preMigrationNames(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("pre-migration").path)) ?? []).sorted()
    }

    // MARK: Safety: the cases that must delete nothing

    /// OC-484-01 (M1). Given an old quarantine, stale copy sidecars and a database at version 1, when this launch
    /// migrates it to version 2, then the copy this launch took and the old quarantine are both still on disk: a launch
    /// cannot confirm its own migration. Dropping the version check turns this red.
    @Test func theMigratingLaunchDeletesNothing() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock, rows: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldQuarantine = try plantQuarantine(root, stamp: clock.millis - 60 * dayMs)

        let db = try await open(root, clock, Migrations.all + [v2]).get()

        #expect(preMigrationNames(root) == ["flotsam-v1.sqlite"])
        #expect(exists(oldQuarantine))
        #expect(try await db.diagnostics().get().userVersion == 2)
    }

    /// OC-484-02 (M1). Given a migration that takes the database 1 -> 2 on a launch with an *unrelated* stale copy
    /// planted under another name, when the launch migrates, then it replaces only the stale copy it owns and the
    /// copy of this migration exists afterwards. The copy count is exactly one and the next clean launch removes it.
    @Test func aMigrationLeavesExactlyOneCopyAndTheNextCleanLaunchRemovesIt() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock, rows: 5)
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = try plantCopy(root, "flotsam-v0.sqlite", at: clock.now().addingTimeInterval(-40 * 86_400))
        let note = try plantCopy(root, "notes.txt", at: clock.now().addingTimeInterval(-40 * 86_400))

        _ = try await open(root, clock, Migrations.all + [v2]).get()
        #expect(preMigrationNames(root) == ["flotsam-v1.sqlite", "notes.txt"])
        #expect(!exists(stale))

        clock.advance(ms: 60_000)  // a minute later: no waiting period
        _ = try await open(root, clock, Migrations.all + [v2]).get()
        #expect(preMigrationNames(root) == ["notes.txt"])
        #expect(exists(note))
    }

    /// OC-484-03 (M1). Given a migration that throws, when the launch runs and fails (STO-DB-003) and again with a
    /// fixed migration, then the failing launches delete nothing, the copy taken before the failed attempt stays, and
    /// the launch that finally migrates still keeps its copy; only the launch after that deletes it.
    @Test func aFailedMigrationThenAFixedOneNeverDeletesBeforeAConfirmingLaunch() async throws {
        struct Boom: Error {}
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock, rows: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let quarantine = try plantQuarantine(root, stamp: clock.millis - 45 * dayMs)
        let broken = Migration(version: 2) { _ in throw Boom() }

        for _ in 0..<2 {
            guard case .failure(let error) = await open(root, clock, Migrations.all + [broken]) else {
                Issue.record("the broken migration must fail the launch"); return
            }
            #expect(error.code == .stoDb003)
            #expect(preMigrationNames(root) == ["flotsam-v1.sqlite"])
            #expect(exists(quarantine))
        }

        _ = try await open(root, clock, Migrations.all + [v2]).get()
        #expect(preMigrationNames(root) == ["flotsam-v1.sqlite"], "the migrating launch keeps its copy")
        #expect(exists(quarantine))

        _ = try await open(root, clock, Migrations.all + [v2]).get()
        #expect(preMigrationNames(root) == [])
        #expect(!exists(quarantine))
    }

    /// OC-484-04 (M2). Given a migrated database whose index pages are orphaned (it reads and migrates normally, only
    /// `quick_check` sees the damage), when the next launch opens it, then the integrity check fails, the database is quarantined with its rows, a new
    /// empty library starts, and the copy is NOT deleted (that launch did not confirm anything). With the integrity
    /// check removed the launch "opens" the damaged file and deletes the copy, so this goes red.
    @Test func aLaunchWhoseIntegrityCheckFailsDeletesNoCopy() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock, rows: 400)
        defer { try? FileManager.default.removeItem(at: root) }
        let migrations = Migrations.all + [v2]
        _ = try await open(root, clock, migrations).get()  // migrates, takes the copy; the launch then ends
        let copy = root.appendingPathComponent("pre-migration/flotsam-v1.sqlite")
        #expect(exists(copy))

        // Orphan the pages of two indexes: every row still reads and the header and version are intact, so nothing
        // throws, and only `PRAGMA quick_check` ("Page N: never used") can tell the file is damaged.
        let main = root.appendingPathComponent("flotsam.sqlite")
        // The system SQLite linked into the app runs defensive (sqlite_master is read-only there), so the fixture is
        // damaged with the sqlite3 command line tool, which is allowed to.
        func sqlite3(_ sql: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [main.path, sql]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try sqlite3("PRAGMA writable_schema = ON; DELETE FROM sqlite_master WHERE name IN ('item_contentKey', 'item_lastCopiedAt'); PRAGMA writable_schema = OFF;")
        #expect(try sqlite3("PRAGMA quick_check;") != "ok", "fixture must fail quick_check")
        #expect(try sqlite3("SELECT COUNT(*) FROM item;") == "400", "every row must still read")

        let reopened = try await open(root, clock, migrations).get()

        #expect(reopened.openNotice?.code == .stoDb002)
        #expect(exists(copy), "a launch that quarantined confirmed nothing")
        let quarantines = (try FileManager.default.contentsOfDirectory(atPath: root.path)).filter { $0.hasPrefix("corrupt-") }
        #expect(quarantines.count == 1)
    }

    /// OC-484-05. Given a database written by a newer app and a copy, a stale quarantine and a stray sidecar, when
    /// this build opens it, then STO-DB-003 is raised and nothing on disk is deleted or changed.
    @Test func aNewerVersionDatabaseFailsTheLaunchAndDeletesNothing() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock, rows: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await open(root, clock, Migrations.all + [v2]).get()
        let quarantine = try plantQuarantine(root, stamp: clock.millis - 90 * dayMs)
        let before = try Data(contentsOf: root.appendingPathComponent("flotsam.sqlite"))

        guard case .failure(let error) = await open(root, clock, Migrations.all) else {
            Issue.record("a newer database must be refused"); return
        }

        #expect(error.code == .stoDb003)
        #expect(preMigrationNames(root) == ["flotsam-v1.sqlite"])
        #expect(exists(quarantine))
        #expect(try Data(contentsOf: root.appendingPathComponent("flotsam.sqlite")) == before)
    }

    /// OC-484-05b. Given a damaged database and an already-expired quarantine, when the launch quarantines the damaged
    /// file, then the expired quarantine is not removed by that launch either (a launch that quarantines deletes
    /// nothing), and the copy stays.
    @Test func theQuarantiningLaunchDeletesNothingElse() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = try plantCopy(root, "flotsam-v1.sqlite", at: clock.now().addingTimeInterval(-3_600))
        let expired = try plantQuarantine(root, stamp: clock.millis - 31 * dayMs)
        for url in DataFolder(root: root).databaseFileURLs { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0xAB, count: 8192).write(to: root.appendingPathComponent("flotsam.sqlite"))

        let db = try await open(root, clock, Migrations.all).get()

        #expect(db.openNotice?.code == .stoDb002)
        #expect(exists(copy))
        #expect(exists(expired))
    }

    // MARK: Quarantine guard (M3)

    /// OC-484-06 (M3). Given a quarantine made 1 hour ago and a copy taken 2 hours ago, when a clean launch runs, then
    /// the copy stays (the quarantine is newer); given a second copy taken 30 minutes ago (newer than the quarantine),
    /// then that one is deleted in the same launch. Inverting the guard swaps the two outcomes.
    @Test func theGuardKeepsOnlyCopiesOlderThanAStandingQuarantine() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let quarantine = try plantQuarantine(root, stamp: clock.millis - 3_600_000)
        let older = try plantCopy(root, "flotsam-v1.sqlite", at: clock.now().addingTimeInterval(-7_200))
        let newer = try plantCopy(root, "flotsam-v2.sqlite", at: clock.now().addingTimeInterval(-1_800))

        _ = try await open(root, clock, Migrations.all).get()

        #expect(exists(older))
        #expect(!exists(newer))
        #expect(exists(quarantine))
    }

    /// OC-484-07 (M3). Boundary: a copy dated exactly the quarantine's stamp is kept, one second later is deleted, and
    /// with no quarantine at all a one-minute-old copy is deleted. The guard can only keep, never delete more.
    @Test func theGuardBoundaryAndTheNoQuarantineCase() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let stampDate = Date(timeIntervalSince1970: (clock.now().timeIntervalSince1970 - 3_600).rounded())
        let quarantine = try plantQuarantine(root, stamp: millis(stampDate))
        let atStamp = try plantCopy(root, "flotsam-v1.sqlite", at: stampDate)
        let afterStamp = try plantCopy(root, "flotsam-v2.sqlite", at: stampDate.addingTimeInterval(1))

        _ = try await open(root, clock, Migrations.all).get()
        #expect(exists(atStamp))
        #expect(!exists(afterStamp))

        try FileManager.default.removeItem(at: quarantine)
        let young = try plantCopy(root, "flotsam-v3.sqlite", at: clock.now().addingTimeInterval(-60))
        _ = try await open(root, clock, Migrations.all).get()
        #expect(!exists(atStamp) && !exists(young))
    }

    /// OC-484-07b. Given a quarantine that cannot be removed although it is 31 days old, when a clean launch runs,
    /// then it still counts as standing: the copy older than it is kept (the guard errs toward keeping).
    @Test func anExpiredQuarantineThatCannotBeRemovedStillGuardsTheCopy() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = clock.millis - 31 * dayMs
        let quarantine = try plantQuarantine(root, stamp: stamp)
        let copy = try plantCopy(root, "flotsam-v1.sqlite", at: Date(timeIntervalSince1970: Double(stamp - dayMs) / 1000))
        let stuck = FaultyFileSystem(failRemove: { $0.lastPathComponent.hasPrefix("corrupt-") })

        _ = try await open(root, clock, Migrations.all, fs: stuck).get()

        #expect(exists(quarantine) && exists(copy))
    }

    // MARK: Sidecars and what is touched (M4)

    /// OC-484-08 (M4). Given a copy with its -wal and -shm and a second-generation copy `flotsam-v1-2.sqlite` with its
    /// own sidecars, plus foreign look-alikes, when a launch confirms, then exactly the six Flotsam-named files go and
    /// the four foreign entries stay, by name.
    @Test func sidecarsGoWithTheirCopyAndForeignEntriesStay() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let when = clock.now().addingTimeInterval(-120)
        for name in ["flotsam-v1.sqlite", "flotsam-v1.sqlite-wal", "flotsam-v1.sqlite-shm",
                     "flotsam-v1-2.sqlite", "flotsam-v1-2.sqlite-wal", "flotsam-v1-2.sqlite-shm"] {
            try plantCopy(root, name, at: when)
        }
        for name in ["flotsam-v1.sqlite.bak", "flotsam-v1.sqlite-journal", "flotsam-v1.sqlite-wal.old", "notes.txt"] {
            try plantCopy(root, name, at: when)
        }

        _ = try await open(root, clock, Migrations.all).get()

        #expect(preMigrationNames(root) == ["flotsam-v1.sqlite-journal", "flotsam-v1.sqlite-wal.old", "flotsam-v1.sqlite.bak", "notes.txt"])
    }

    /// OC-484-09. Given links and folders carrying Flotsam's names (a link to a file outside the data folder named like
    /// a -wal, a folder named like a -shm with a file inside, a link named `corrupt-<n>` to a folder outside), when a
    /// launch confirms and quarantines expire, then the links, the folder and everything outside are untouched.
    @Test func linksAndFoldersCarryingFlotsamNamesAreNeverFollowedOrRemoved() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("w484-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("dir"), withIntermediateDirectories: true)
        let victimFile = outside.appendingPathComponent("victim.txt")
        let victimInDir = outside.appendingPathComponent("dir/inside.txt")
        try Data("keep".utf8).write(to: victimFile)
        try Data("keep".utf8).write(to: victimInDir)
        let preMigration = root.appendingPathComponent("pre-migration")
        try FileManager.default.createDirectory(at: preMigration, withIntermediateDirectories: true)
        let wal = preMigration.appendingPathComponent("flotsam-v1.sqlite-wal")
        let main = preMigration.appendingPathComponent("flotsam-v1.sqlite")
        let shmFolder = preMigration.appendingPathComponent("flotsam-v1.sqlite-shm")
        try FileManager.default.createSymbolicLink(at: wal, withDestinationURL: victimFile)
        try FileManager.default.createSymbolicLink(at: main, withDestinationURL: outside.appendingPathComponent("dir"))
        try FileManager.default.createDirectory(at: shmFolder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: shmFolder.appendingPathComponent("held.txt"))
        let oldLink = root.appendingPathComponent("corrupt-\(clock.millis - 40 * dayMs)")
        try FileManager.default.createSymbolicLink(at: oldLink, withDestinationURL: outside.appendingPathComponent("dir"))

        _ = try await open(root, clock, Migrations.all).get()

        #expect(isLink(wal) && isLink(main) && isLink(oldLink))
        #expect(exists(shmFolder.appendingPathComponent("held.txt")))
        #expect(exists(victimFile) && exists(victimInDir))
    }

    /// OC-484-10. Given a copy that cannot be removed and one that can, when a launch confirms, then the launch
    /// succeeds, the removable one and its sidecars go, the stuck one stays; the next launch (file system healthy)
    /// removes it. Count delta exactly 2 then 1.
    @Test func aStuckCopyDoesNotStopTheLaunchOrItsNeighboursAndIsRetried() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let when = clock.now().addingTimeInterval(-120)
        try plantCopy(root, "flotsam-v1.sqlite", at: when)
        try plantCopy(root, "flotsam-v1.sqlite-wal", at: when)
        try plantCopy(root, "flotsam-v2.sqlite", at: when)

        _ = try await open(root, clock, Migrations.all, fs: FaultyFileSystem(failRemove: { $0.lastPathComponent == "flotsam-v2.sqlite" })).get()
        #expect(preMigrationNames(root) == ["flotsam-v2.sqlite"])

        _ = try await open(root, clock, Migrations.all).get()
        #expect(preMigrationNames(root) == [])
    }

    // MARK: Quarantine expiry (30 days, one home)

    /// OC-484-11. Quarantines 30 days exactly, 30 days minus 1 ms, and 30 days plus 1 ms: the first and last are gone,
    /// the middle stays. A 7-day-old quarantine stays too (the 7-day rule is gone for copies and was never for these).
    @Test func quarantinesExpireAtExactlyThirtyDays() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let exact = try plantQuarantine(root, stamp: clock.millis - 2_592_000_000)
        let justUnder = try plantQuarantine(root, stamp: clock.millis - 2_592_000_000 + 1)
        let over = try plantQuarantine(root, stamp: clock.millis - 2_592_000_000 - 1)
        let week = try plantQuarantine(root, stamp: clock.millis - 7 * dayMs)

        _ = try await open(root, clock, Migrations.all).get()

        #expect(!exists(exact) && !exists(over))
        #expect(exists(justUnder) && exists(week))
    }

    /// OC-484-12. The retention constant has one definition: 30 days in ms, and no second literal for it in the
    /// storage sources.
    @Test func theQuarantineRetentionHasOneHome() throws {
        #expect(DataFolder.quarantineRetentionMillis == 2_592_000_000)
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FlotsamStorage")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 10)
        let hits = files.filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains("2_592_000_000") == true
            || (try? String(contentsOf: $0, encoding: .utf8))?.contains("quarantineRetentionMillis") == true }
        #expect(hits.map(\.lastPathComponent).sorted() == ["FlotsamDatabase.swift", "PlaintextCopies.swift"])
    }

    // MARK: Clock skew

    /// OC-484-13 (characterisation, Minor). Given a quarantine made at the true time (1 hour ago) and a copy whose
    /// file dates are a day in the FUTURE (the clock was wrong when it was taken), when a clean launch runs, then the
    /// guard compares dates, sees the copy as newer, and deletes it even though the quarantine really came after it.
    /// This is the literal ruling's behaviour (a confirmed launch deletes the copy), so the skew can only fall back to
    /// it, never delete more than the ruling allows. Pinned so a change is noticed.
    @Test func aFutureDatedCopyIsDeletedDespiteAStandingQuarantine() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let quarantine = try plantQuarantine(root, stamp: clock.millis - 3_600_000)
        let future = try plantCopy(root, "flotsam-v1.sqlite", at: clock.now().addingTimeInterval(86_400))

        _ = try await open(root, clock, Migrations.all).get()

        #expect(!exists(future))
        #expect(exists(quarantine))
    }

    /// OC-484-14 (Minor). Given a quarantine stamped a day in the future (clock skew when it was made), when a clean
    /// launch runs, then it is not expired (age is negative) and the older copy is kept: skew can only keep more.
    @Test func aFutureStampedQuarantineIsKeptAndKeepsTheCopy() async throws {
        let clock = ManualClock()
        let root = try await makeFolder(clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let quarantine = try plantQuarantine(root, stamp: clock.millis + dayMs)
        let copy = try plantCopy(root, "flotsam-v1.sqlite", at: clock.now().addingTimeInterval(-3_600))

        _ = try await open(root, clock, Migrations.all).get()

        #expect(exists(quarantine) && exists(copy))
    }

    // MARK: Clear History still purges both

    /// OC-484-15. Given a copy with sidecars and a young quarantine, when Clear History deletes an item, then the three
    /// are gone and a foreign file stays; with the guard standing it still purges (Clear History is not guarded).
    @Test func clearHistoryStillRemovesACopyThatAQuarantineGuards() async throws {
        let clock = ManualClock()
        let store = try await Store.make(clock: clock)
        defer { store.cleanUp() }
        try await store.insert(Spec(n: 1, ageMs: 60_000))
        let quarantine = try plantQuarantine(store.root, stamp: clock.millis - 3_600_000)
        let copy = try plantCopy(store.root, "flotsam-v1.sqlite", at: clock.now().addingTimeInterval(-7_200))
        let wal = try plantCopy(store.root, "flotsam-v1.sqlite-wal", at: clock.now().addingTimeInterval(-7_200))
        let foreign = try plantCopy(store.root, "notes.txt", at: clock.now().addingTimeInterval(-7_200))

        let outcome = try await store.database.clearHistory(range: .allTime, includeExempt: true).get()

        #expect(outcome.deletedCount == 1)
        #expect(!exists(copy) && !exists(wal) && !exists(quarantine))
        #expect(exists(foreign))
    }
}
