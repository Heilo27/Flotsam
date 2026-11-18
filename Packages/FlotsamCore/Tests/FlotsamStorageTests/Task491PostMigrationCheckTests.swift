import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-491 (Worf on TASK-484, W-1). FR-007-13 runs `quick_check` a second time, on the migrated file, and a failing
// result must send the open down the damaged path. The existing post-migration tests damage the file behind SQLite's
// back; none of them reaches a launch that runs no migration (the confirming launch of FR-007-17), because the pre-open
// probe already vouches for the same bytes there. The ADR-0011 seam `postMigrationCheck` fails that one check on a
// healthy file, so the confirming launch can be driven to it.
//
// Mutation this is written to kill:
//   M2b ignore the post-migration check result (`passed ? .opened : .damaged` becomes `.opened`).

@Suite struct Task491PostMigrationCheckTests {
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private var v2: Migration { Migration(version: 2) { db in try db.execute(sql: "CREATE TABLE probe (id INTEGER)") } }

    /// Fails the first post-migration check it is asked for and passes every later one, so the fresh database made by
    /// the second open attempt is judged healthy.
    private final class FailsOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func check(_ db: Database) throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return calls > 1
        }
    }

    private func corruptFolders(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("corrupt-") }
    }

    /// Given a migrated database and the pre-migration copy its migration left, when the next launch (which runs no
    /// migration) finds the post-migration check failing, then that launch quarantines the file, raises STO-DB-002 and
    /// deletes nothing: the copy stays. Ignoring the check result turns this red: the launch would open the file,
    /// confirm the migration and delete the copy.
    @Test func aFailingPostMigrationCheckOnAConfirmingLaunchQuarantinesAndKeepsTheCopy() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let migrations = Migrations.all + [v2]
        _ = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: clock, migrations: migrations).get()
        let copy = root.appendingPathComponent("pre-migration/\(DataFolder.preMigrationCopyName(fromVersion: 1))")
        #expect(exists(copy), "arrange: the migrating launch took a copy")
        #expect(corruptFolders(root).isEmpty, "arrange: nothing is quarantined yet")
        clock.advance(ms: hourMs)
        let seam = FailsOnce()

        let reopened = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: clock, migrations: migrations,
            postMigrationCheck: seam.check
        ).get()

        #expect(seam.callCount == 2, "the check ran on the migrated file, then on the fresh one")
        #expect(reopened.openNotice?.code == .stoDb002)
        #expect(corruptFolders(root).count == 1)
        #expect(exists(copy), "a launch whose check failed confirms nothing, so it deletes nothing")
    }

    /// The control for the test above: the same launch with a check that passes confirms the migration and deletes the
    /// copy, so the copy surviving above is the failing check's doing and not an artefact of the arrangement.
    @Test func aPassingPostMigrationCheckOnAConfirmingLaunchDeletesTheCopy() async throws {
        let clock = ManualClock()
        let first = try await Store.make(clock: clock)
        let root = first.root
        defer { first.cleanUp() }
        let migrations = Migrations.all + [v2]
        _ = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: clock, migrations: migrations).get()
        let copy = root.appendingPathComponent("pre-migration/\(DataFolder.preMigrationCopyName(fromVersion: 1))")
        #expect(exists(copy), "arrange: the migrating launch took a copy")
        clock.advance(ms: hourMs)

        let reopened = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), clock: clock, migrations: migrations,
            postMigrationCheck: { _ in true }
        ).get()

        #expect(reopened.openNotice == nil)
        #expect(corruptFolders(root).isEmpty)
        #expect(!exists(copy))
    }
}
