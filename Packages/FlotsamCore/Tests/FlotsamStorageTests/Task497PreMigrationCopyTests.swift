import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-497 / FR-007-17, AC-007-22. The pre-migration copy holds every committed row even when a reader keeps a
// checkpoint from finishing. It used to run `wal_checkpoint(TRUNCATE)`, ignore the `busy` column of its result row, and
// copy the main file alone, so frames still in `-wal` were silently missing from the one copy that is the rollback for
// a migration. Expected values are literals (item numbers, versions, the error code, the file mode).
//
// Mutations these are written to kill:
//   M1 the old behaviour restored: checkpoint with the busy column ignored, then `copyItem` of the main file only.
//   M2 a failed publish of the copy swallowed (the failure reported as success).

/// Local file system whose `replaceItem` into `pre-migration/` can be made to fail; every other call is the real one.
private final class Task497FileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    let failPublish = Cell<Bool>(false)

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with source: URL) -> FlotsamResult<Void> {
        if failPublish.value, destination.deletingLastPathComponent().lastPathComponent == FlotsamDatabase.preMigrationFolderName {
            return .failure(FlotsamError(.stoIo001, "injected publish failure"))
        }
        return real.replaceItem(at: destination, with: source)
    }
    func removeItem(at url: URL) -> FlotsamResult<Void> { real.removeItem(at: url) }
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

@Suite struct Task497PreMigrationCopyTests {
    private let addProbe = Migration(version: 2) { db in try db.execute(sql: "CREATE TABLE probe (id INTEGER)") }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-497-\(UUID().uuidString)")
    }

    private func itemIds(inFileAlone url: URL) throws -> (version: Int, ids: Set<Int>) {
        // A private copy of the one file, so what is read is exactly what is inside it (no -wal beside it).
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-497-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("only.sqlite")
        try FileManager.default.copyItem(at: url, to: copy)
        return try DatabaseQueue(path: copy.path).read { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
            let ids = try String.fetchAll(db, sql: "SELECT id FROM item")
            return (version, Set(ids.map { Int(String($0.suffix(12)))! }))
        }
    }

    /// Holds a read transaction on its own connection until `release()`: the snapshot it took blocks any checkpoint from
    /// folding later WAL frames into the main file, so a `TRUNCATE` checkpoint reports `busy = 1`.
    private final class HeldReader: @unchecked Sendable {
        private let queue: DatabaseQueue
        private let released = DispatchSemaphore(value: 0)
        private let finished = DispatchSemaphore(value: 0)

        init(path: String) throws {
            queue = try DatabaseQueue(path: path)
            let ready = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { [queue, released, finished] in
                try? queue.inDatabase { db in
                    try db.inTransaction(.deferred) {
                        _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM item")
                        ready.signal()
                        released.wait()
                        return .commit
                    }
                }
                finished.signal()
            }
            ready.wait()
        }

        func release() {
            released.signal()
            finished.wait()
        }
    }

    /// A version-1 library of items 1...3 whose last connection closed cleanly, then a reader holding that snapshot,
    /// then a second connection committing items 4 and 5, which therefore exist only in `-wal` (the reader keeps every
    /// checkpoint from moving them). Returns the root, the held reader and the writer to keep alive.
    private func arrange() async throws -> (root: URL, reader: HeldReader, writer: Store) {
        let root = tempRoot()
        do {
            let first = try await Store.make(root: root, migrations: Migrations.baseline)
            try await first.insert((1...3).map { Spec(n: $0, ageMs: hourMs) })
        }
        let reader = try HeldReader(path: root.appendingPathComponent(FlotsamDatabase.fileName).path)
        let writer = try await Store.make(root: root, migrations: Migrations.baseline)
        try await writer.insert((4...5).map { Spec(n: $0, ageMs: hourMs) })
        let main = try itemIds(inFileAlone: root.appendingPathComponent(FlotsamDatabase.fileName))
        try #require(main.ids != [1, 2, 3, 4, 5], "fixture is not WAL-resident: the main file already holds items 4 and 5")
        return (root, reader, writer)
    }

    /// AC-007-22. Given a reader holding the WAL so the checkpoint cannot finish, and items 4 and 5 committed only in
    /// `-wal`, when a release adds migration 2 and the database opens, then `pre-migration/flotsam-v1.sqlite` on its own
    /// holds items 1 to 5 at user_version 1, with mode 0600, and the live database migrated to 2 with all five.
    @Test("OC-497-01 a reader blocking the checkpoint cannot make the pre-migration copy miss committed rows")
    func heldReaderCopyIsComplete() async throws {
        let (root, reader, writer) = try await arrange()
        defer { try? FileManager.default.removeItem(at: root) }

        let upgraded = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.baseline + [addProbe], busyTimeout: 0.3
        ).get()
        reader.release()

        let copyURL = root.appendingPathComponent("pre-migration/flotsam-v1.sqlite")
        let copy = try itemIds(inFileAlone: copyURL)
        #expect(copy.version == 1)
        #expect(copy.ids == [1, 2, 3, 4, 5])
        let mode = try FileManager.default.attributesOfItem(atPath: copyURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try await upgraded.pragmaFacts().userVersion == 2)
        withExtendedLifetime(writer) {}
    }

    /// AC-007-22. Given the copy cannot be put in place, then the open fails with STO-DB-003 before any migration, the
    /// earlier copy is untouched, no partial copy and no scratch file is left, and the live database is still at 1.
    @Test("OC-497-02 a copy that cannot be completed is reported failed and leaves no partial file")
    func failedCopyIsReportedAndLeavesNothingPartial() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let first = try await Store.make(root: root, migrations: Migrations.baseline)
            try await first.insert((1...3).map { Spec(n: $0, ageMs: hourMs) })
        }
        let folder = root.appendingPathComponent("pre-migration")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let earlier = folder.appendingPathComponent("flotsam-v1.sqlite")
        try Data("earlier copy".utf8).write(to: earlier)
        let fileSystem = Task497FileSystem()
        fileSystem.failPublish.value = true

        let result = await FlotsamDatabase.open(
            folder: root, fileSystem: fileSystem, migrations: Migrations.baseline + [addProbe], busyTimeout: 0.3)

        guard case .failure(let error) = result else { Issue.record("the open succeeded with no pre-migration copy"); return }
        #expect(error.code == .stoDb003)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["flotsam-v1.sqlite"])
        #expect(try String(contentsOf: earlier, encoding: .utf8) == "earlier copy")
        let scratch = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tmp").path)
        #expect(scratch.filter { $0.hasPrefix("premigration-") }.isEmpty)
        let live = try itemIds(inFileAlone: root.appendingPathComponent(FlotsamDatabase.fileName))
        #expect(live.version == 1)
    }
}
