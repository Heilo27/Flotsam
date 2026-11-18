import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// Security F1 / F5 (FRD-007 FR-007-01, -11, -13, -17; AC-007-17 to AC-007-20). The pre-migration backup and the
// corrupt-database quarantine are full plaintext copies of the database, so they obey the same deletion promise as the
// rows: Clear History removes them, and each expires on its own clock. Folders and database files are owner-only from
// creation. Every test works in a temporary folder.
//
// TASK-484 (audit F-01): a pre-migration copy is deleted by the first launch that confirms the migration (opens cleanly
// at the migrated schema version), not after a waiting period; a quarantine still lasts 30 days.

@Suite struct PlaintextCopiesTests {
    private func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A file in `pre-migration/` whose creation and modification dates are `ageMs` before the store's clock.
    @discardableResult
    private func plantCopy(_ s: Store, _ name: String, ageMs: Int64) throws -> URL {
        let url = try s.plant("pre-migration/\(name)", contents: "plaintext-\(name)")
        let when = s.clock.now().addingTimeInterval(-Double(ageMs) / 1000)
        try FileManager.default.setAttributes([.creationDate: when, .modificationDate: when], ofItemAtPath: url.path)
        return url
    }

    /// A quarantine folder named for a creation time `ageMs` before the store's clock, holding a database copy.
    @discardableResult
    private func plantQuarantine(_ s: Store, ageMs: Int64) throws -> URL {
        let stamp = s.clock.millis - ageMs
        let folder = s.root.appendingPathComponent("corrupt-\(stamp)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("plaintext-corrupt".utf8).write(to: folder.appendingPathComponent("flotsam.sqlite"))
        return folder
    }

    // MARK: Clear History (AC-007-17)

    /// Given a pre-migration copy with its WAL and a quarantine folder, when Clear History deletes items, then every
    /// copy is gone, the live database and the files Flotsam did not write stay.
    @Test func clearHistoryPurgesPreMigrationCopiesAndQuarantines() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert((1...3).map { Spec(n: $0, ageMs: Int64($0) * 60_000) })
        let copy = try plantCopy(s, "flotsam-v1.sqlite", ageMs: 60_000)
        let copyWal = try plantCopy(s, "flotsam-v1.sqlite-wal", ageMs: 60_000)
        let quarantine = try plantQuarantine(s, ageMs: dayMs)
        let note = try s.plant("pre-migration/notes.txt")
        let backupLookalike = try s.plant("pre-migration/flotsam-v1.sqlite.bak")
        let foreignFolder = try s.plant("corrupt-abc/keep.txt")
        let foreignFile = try s.plant("corrupt-77")  // a regular file, not a folder Flotsam made

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: true).get()

        #expect(outcome.deletedCount == 3)
        #expect(outcome.plaintextCopiesPurged)
        #expect(!exists(copy) && !exists(copyWal) && !exists(quarantine))
        #expect(exists(note) && exists(backupLookalike) && exists(foreignFolder) && exists(foreignFile))
        #expect(try s.count("item") == 0)
    }

    /// Given a copy that cannot be removed, when Clear History runs, then the rest are still purged, the clear itself
    /// succeeds, the outcome says the purge was incomplete and the failure is logged.
    @Test func clearHistoryReportsAnIncompletePurgeAndKeepsGoing() async throws {
        let fileSystem = FaultyFileSystem(failRemove: { $0.lastPathComponent == "flotsam-v1.sqlite" })
        let s = try await Store.make(fileSystem: fileSystem)
        defer { s.cleanUp() }
        try await s.insert(Spec(n: 1, ageMs: 60_000))
        let stuck = try plantCopy(s, "flotsam-v1.sqlite", ageMs: 60_000)
        let other = try plantCopy(s, "flotsam-v1.sqlite-shm", ageMs: 60_000)
        let quarantine = try plantQuarantine(s, ageMs: dayMs)

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: true).get()

        #expect(outcome.deletedCount == 1)
        #expect(!outcome.plaintextCopiesPurged)
        #expect(exists(stuck))
        #expect(!exists(other) && !exists(quarantine))
        #expect(!s.logs.lines(containing: ["plaintext database copies"]).isEmpty)
    }

    /// Given a range that matches nothing, when Clear History runs, then nothing was cleared and the copies stay.
    @Test func clearHistoryThatDeletesNothingLeavesTheCopies() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        let copy = try plantCopy(s, "flotsam-v1.sqlite", ageMs: 60_000)
        let quarantine = try plantQuarantine(s, ageMs: dayMs)

        let outcome = try await s.database.clearHistory(range: .allTime, includeExempt: true).get()

        #expect(outcome.deletedCount == 0)
        #expect(exists(copy) && exists(quarantine))
    }

    // MARK: Launch cleanup (AC-007-18, AC-007-19)

    /// The migration a "later release" adds on top of the shipped ones, so a database at version 1 migrates to 2.
    private var extraMigration: Migration {
        Migration(version: 2) { db in try db.execute(sql: "CREATE TABLE probe (id INTEGER)") }
    }

    private func open(_ root: URL, _ clock: ManualClock, migrations: [Migration]) async -> FlotsamResult<FlotsamDatabase> {
        await FlotsamDatabase.open(folder: root, fileSystem: LocalFileSystem(), clock: clock, migrations: migrations)
    }

    private func takenCopy(_ root: URL, fromVersion: Int = 1) -> URL {
        root.appendingPathComponent("pre-migration/\(DataFolder.preMigrationCopyName(fromVersion: fromVersion))")
    }

    /// Given a pre-migration copy of any age with its WAL and shared-memory files, when the app opens cleanly with
    /// nothing to migrate (the confirming launch), then all three are deleted at once, even the minute-old one, and
    /// files Flotsam did not name stay.
    @Test func aConfirmingLaunchDeletesTheCopyAtOnceWithItsSidecars() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let copy = try plantCopy(first, "flotsam-v1.sqlite", ageMs: 60_000)
        let copyWal = try plantCopy(first, "flotsam-v1.sqlite-wal", ageMs: 60_000)
        let copyShm = try plantCopy(first, "flotsam-v1.sqlite-shm", ageMs: 8 * dayMs)
        let second = try plantCopy(first, "flotsam-v1-2.sqlite", ageMs: 1_000)
        let note = try plantCopy(first, "notes.txt", ageMs: 90 * dayMs)
        let lookalike = try plantCopy(first, "flotsam-v1.sqlite.bak", ageMs: 90 * dayMs)

        _ = try await Store.make(root: root, clock: clock)

        #expect(!exists(copy) && !exists(copyWal) && !exists(copyShm) && !exists(second))
        #expect(exists(note) && exists(lookalike))
    }

    /// Given a launch that migrates a real database, when the next launch opens it cleanly, then the copy the first
    /// launch took (and its sidecars) is deleted by that second launch and not by the first; an old quarantine goes
    /// with it.
    @Test func theLaunchThatMigratesKeepsTheCopyAndTheNextCleanLaunchDeletesIt() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let oldQuarantine = try plantQuarantine(first, ageMs: 60 * dayMs)
        let migrations = Migrations.all + [extraMigration]

        let migrated = try await open(root, clock, migrations: migrations).get()
        let copy = takenCopy(root)
        let sidecars = [try first.plant("pre-migration/flotsam-v1.sqlite-wal"), try first.plant("pre-migration/flotsam-v1.sqlite-shm")]
        #expect(exists(copy), "the migrating launch took a copy")
        #expect(exists(oldQuarantine), "the migrating launch deletes nothing")
        _ = migrated

        let confirmed = try await open(root, clock, migrations: migrations).get()

        #expect(!exists(copy) && sidecars.allSatisfy { !exists($0) })
        #expect(!exists(oldQuarantine))
        _ = confirmed
    }

    /// Given the app quit or crashed after migrating and before any later launch, then the copy is still there however
    /// much time passes: nothing but a confirming launch deletes it.
    @Test func aCrashBetweenMigratingAndConfirmingKeepsTheCopy() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }

        do { _ = try await open(root, clock, migrations: Migrations.all + [extraMigration]).get() }  // the launch ends here
        clock.advance(ms: 400 * dayMs)

        #expect(exists(takenCopy(root)))

        // and the launch that finally runs, and confirms, is the one that deletes it
        _ = try await open(root, clock, migrations: Migrations.all + [extraMigration]).get()
        #expect(!exists(takenCopy(root)))
    }

    /// Given a migrated database that the next launch finds damaged, when that launch quarantines it, then the copy
    /// stays (a failed confirm deletes nothing), and it stays on the launch after, which opens the fresh empty library
    /// cleanly, because the quarantine made after the copy still stands.
    @Test func aDamagedConfirmingLaunchKeepsTheCopy() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let migrations = Migrations.all + [extraMigration]
        _ = try await open(root, clock, migrations: migrations).get()
        let copy = takenCopy(root)
        #expect(exists(copy))
        clock.advance(ms: hourMs)
        for url in DataFolder(root: root).databaseFileURLs { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0xAB, count: 8192).write(to: root.appendingPathComponent("flotsam.sqlite"))

        let quarantined = try await open(root, clock, migrations: migrations).get()
        #expect(quarantined.openNotice?.code == .stoDb002)
        #expect(exists(copy), "the launch that quarantined deletes nothing")

        clock.advance(ms: hourMs)
        _ = try await open(root, clock, migrations: migrations).get()
        #expect(exists(copy), "the quarantine newer than the copy still stands, so the copy may be the last good data")

        clock.advance(ms: 30 * dayMs)
        _ = try await open(root, clock, migrations: migrations).get()
        #expect(!exists(copy), "30 days on the quarantine is gone and a clean launch deletes the copy")
    }

    /// Given a migrated database that a later launch cannot open (it was written by a newer version, STO-DB-003), then
    /// that launch fails and the copy stays.
    @Test func aFailedConfirmingLaunchKeepsTheCopy() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        _ = try await open(root, clock, migrations: Migrations.all + [extraMigration]).get()
        let copy = takenCopy(root)

        let result = await open(root, clock, migrations: Migrations.all)  // this build only knows version 1

        guard case .failure(let error) = result else { Issue.record("expected the open to fail"); return }
        #expect(error.code == .stoDb003)
        #expect(exists(copy))
    }

    /// Given a quarantine made after a copy and one made before it, when a confirming launch runs, then the copy is
    /// kept while the newer quarantine stands; the older one does not matter. A quarantine 30 days old is removed first,
    /// which releases the copy in that same launch.
    @Test func aNewerQuarantineHoldsTheCopyOnlyWhileItStands() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let copy = try plantCopy(first, "flotsam-v1.sqlite", ageMs: 10 * dayMs)
        let olderQuarantine = try plantQuarantine(first, ageMs: 11 * dayMs)
        let newerQuarantine = try plantQuarantine(first, ageMs: 9 * dayMs)

        _ = try await Store.make(root: root, clock: clock)
        #expect(exists(copy) && exists(olderQuarantine) && exists(newerQuarantine))

        clock.advance(ms: 21 * dayMs)  // the newer quarantine is now 30 days old, the copy 31
        _ = try await Store.make(root: root, clock: clock)
        #expect(!exists(copy) && !exists(olderQuarantine) && !exists(newerQuarantine))
    }

    /// Given quarantines 30 days and 29 days 23 h 59 min 59 s old, when a confirming launch runs, then the first is
    /// removed whole and the second stays, and a pre-migration copy does not shorten or lengthen that.
    @Test func quarantinesStillExpireAtThirtyDays() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let oldQuarantine = try plantQuarantine(first, ageMs: 30 * dayMs)
        let youngQuarantine = try plantQuarantine(first, ageMs: 30 * dayMs - 1_000)
        let foreignFolder = try first.plant("corrupt-old/keep.txt", ageMs: 90 * dayMs)
        let foreignFile = try first.plant("corrupt-77")

        _ = try await Store.make(root: root, clock: clock)

        #expect(!exists(oldQuarantine))
        #expect(exists(youngQuarantine) && exists(foreignFolder) && exists(foreignFile))
    }

    /// Given a copy that cannot be inspected (its size and dates read as nothing), when a launch confirms, then it is
    /// kept: only a regular file Flotsam can see is ever deleted.
    @Test func aCopyThatCannotBeInspectedIsKept() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let copy = try plantCopy(first, "flotsam-v1.sqlite", ageMs: 90 * dayMs)

        _ = try await Store.make(
            fileSystem: FaultyFileSystem(failInfo: { $0.lastPathComponent == "flotsam-v1.sqlite" }), root: root, clock: clock)

        #expect(exists(copy))
    }

    /// Given a copy that cannot be removed at launch, when the app opens, then it still opens.
    @Test func aFailedExpiryDoesNotStopTheLaunch() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let copy = try plantCopy(first, "flotsam-v1.sqlite", ageMs: 90 * dayMs)

        let second = try await Store.make(
            fileSystem: FaultyFileSystem(failRemove: { $0.lastPathComponent == "flotsam-v1.sqlite" }), root: root, clock: clock)

        #expect(exists(copy))
        #expect(try second.count("item") == 0)
    }

    @Test func quarantineStampsAreExactlyCorruptDigits() {
        #expect(DataFolder.quarantineStamp(named: "corrupt-1700000000000") == 1_700_000_000_000)
        for name in ["corrupt-", "corrupt-abc", "corrupt-12a", "corrupt--5", "Corrupt-5", "corrupt-5.bak", "corrupt-\u{0663}"] {
            #expect(DataFolder.quarantineStamp(named: name) == nil, "\(name)")
        }
    }

    // MARK: Modes (AC-007-20)

    /// Given a data folder made by an older build with loose modes, when the app opens, then every Flotsam folder is
    /// 0700 and the database files 0600.
    @Test func openTightensExistingFoldersAndDatabaseFiles() async throws {
        let first = try await Store.make()
        defer { first.cleanUp() }
        let root = first.root
        try await first.insert(Spec(n: 1))
        let quarantine = try plantQuarantine(first, ageMs: dayMs)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pre-migration"), withIntermediateDirectories: true)
        let folders = ["", "blobs", "thumbs", "tmp", "pre-migration"].map { root.appendingPathComponent($0) } + [quarantine]
        let files = ["", "-wal", "-shm"].map { root.appendingPathComponent("flotsam.sqlite" + $0) }
        for url in folders { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        for url in files { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        _ = try await Store.make(root: root, clock: first.clock)

        for url in folders { #expect(mode(url) == 0o700, "\(url.lastPathComponent)") }
        for url in files { #expect(mode(url) == 0o600, "\(url.lastPathComponent)") }
    }

    /// TASK-422 M1. Given `pre-migration/` is a link to a folder outside the data folder with loose modes, when the app
    /// opens, then the target's mode is not changed (`setAttributes` follows links) and the open still succeeds.
    @Test func openDoesNotChmodThroughALinkedPreMigrationFolder() async throws {
        let first = try await Store.make()
        defer { first.cleanUp() }
        let root = first.root
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-m1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("pre-migration"), withDestinationURL: outside)

        _ = try await Store.make(root: root, clock: first.clock)

        #expect(mode(outside) == 0o755)
    }

    /// Given a fresh folder and a permissive umask, when the app creates the database and writes to it, then the
    /// database, WAL and shared-memory files are 0600 from creation (no window at the umask's mode).
    @Test func newDatabaseFilesAreOwnerOnlyFromCreation() async throws {
        let previous = umask(0o022)
        defer { umask(previous) }
        let s = try await Store.make()
        defer { s.cleanUp() }
        try await s.insert((1...5).map { Spec(n: $0) })

        for url in ["", "-wal", "-shm"].map({ s.root.appendingPathComponent("flotsam.sqlite" + $0) }) {
            #expect(exists(url), "\(url.lastPathComponent)")
            #expect(mode(url) == 0o600, "\(url.lastPathComponent)")
        }
    }

    /// Given a data folder whose database file cannot be made owner-only, when the app opens, then it fails with
    /// STO-IO-002 rather than running with a readable database.
    @Test func openFailsWhenTheDatabaseFileCannotBeCreatedOwnerOnly() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = await FlotsamDatabase.open(
            folder: folder, fileSystem: FaultyFileSystem(failWrite: { $0.lastPathComponent == "flotsam.sqlite" }))

        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == .stoIo002)
    }
}
