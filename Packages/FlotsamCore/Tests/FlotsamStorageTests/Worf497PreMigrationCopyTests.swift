import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// Worf, blind verification of TASK-497 / FR-007-17, AC-007-22 (the pre-migration copy is a complete, atomic, owner-only
// snapshot taken by SQLite's online backup). Written from the FRD and the code, not from garak's tests. Expected values
// are literals (item numbers, versions, modes, the error code, file contents).
//
// Mutations these are written to kill (each run by hand against the production code, see the ticket note):
//   M1 the old behaviour: `wal_checkpoint(TRUNCATE)` with the busy column ignored, then `copyItem` of the main file.
//   M2 the backup error swallowed (`try?` around `pool.backup`).
//   M3 the copy published before the backup completes (empty staged file renamed first, backup written afterwards).
//   M4 the staged file created with a mode other than 0600.
//   M5 the scratch directory not removed after the copy (success or failure).
//   M6 the earlier copy removed before the new one is complete (the pre-TASK-497 `removeItem(destination)`).
//   M7 the scratch placed outside the data folder's volume / `tmp/` (the rename would no longer be atomic).

/// Real file system that records what `snapshot` does, can inject one fault per run, and looks at the staged file at the
/// moment it is published.
private final class Worf497FileSystem: FileSystemPort, @unchecked Sendable {
    enum Fault: Sendable, CustomTestStringConvertible {
        case none, scratchCreate, stagedWrite, backupNotADatabase, backupReadOnly, publish
        var testDescription: String {
            switch self {
            case .none: "none"
            case .scratchCreate: "scratch create"
            case .stagedWrite: "staged write"
            case .backupNotADatabase: "backup (destination not a database)"
            case .backupReadOnly: "backup (destination read-only)"
            case .publish: "publish"
            }
        }
    }

    struct Publish {
        var stagedPath: String
        var stagedMode: Int
        var scratchMode: Int
        var sameVolume: Bool
        var stagedVersion: Int?
        var stagedIds: Set<Int>?
        var destinationBytes: Data?
    }

    private let real = LocalFileSystem()
    let fault: Fault
    let events = Cell<[String]>([])
    let removed = Cell<[String]>([])
    let writes = Cell<[(path: String, permissions: Int)]>([])
    let publishes = Cell<[Publish]>([])
    /// Runs after the backup finished and before the rename into place.
    let beforePublish = Cell<@Sendable () -> Void>({})

    init(fault: Fault = .none) { self.fault = fault }

    private static func isScratch(_ url: URL) -> Bool { url.lastPathComponent.hasPrefix("premigration-") }
    private static func inScratch(_ url: URL) -> Bool { isScratch(url.deletingLastPathComponent()) }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> {
        events.mutate { $0.append("create \(url.lastPathComponent)") }
        if fault == .scratchCreate, Self.isScratch(url) { return .failure(FlotsamError(.stoIo001, "injected scratch failure")) }
        return real.createDirectory(at: url, permissions: permissions)
    }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with source: URL) -> FlotsamResult<Void> {
        guard destination.deletingLastPathComponent().lastPathComponent == FlotsamDatabase.preMigrationFolderName else {
            return real.replaceItem(at: destination, with: source)
        }
        events.mutate { $0.append("publish \(destination.lastPathComponent)") }
        beforePublish.value()
        publishes.mutate { $0.append(observe(staged: source, destination: destination)) }
        if fault == .publish { return .failure(FlotsamError(.stoIo001, "injected publish failure")) }
        return real.replaceItem(at: destination, with: source)
    }
    func removeItem(at url: URL) -> FlotsamResult<Void> {
        removed.mutate { $0.append(url.path) }
        return real.removeItem(at: url)
    }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> {
        guard Self.inScratch(url) else { return real.writeFile(data, to: url, permissions: permissions) }
        writes.mutate { $0.append((url.path, permissions)) }
        events.mutate { $0.append("stage \(url.lastPathComponent)") }
        switch fault {
        case .stagedWrite: return .failure(FlotsamError(.stoIo001, "injected stage failure"))
        case .backupNotADatabase: return real.writeFile(Data("this is not a sqlite database".utf8), to: url, permissions: permissions)
        case .backupReadOnly: return real.writeFile(Data(), to: url, permissions: 0o400)
        default: return real.writeFile(data, to: url, permissions: permissions)
        }
    }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { real.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { real.availableCapacity(at: url) }

    private func observe(staged: URL, destination: URL) -> Publish {
        func attributes(_ url: URL) -> [FileAttributeKey: Any] { (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:] }
        let stagedAttributes = attributes(staged)
        let version: Int?
        let ids: Set<Int>?
        if let snapshot = try? Worf497.read(fileAlone: staged) { (version, ids) = (snapshot.version, snapshot.ids) } else { (version, ids) = (nil, nil) }
        return Publish(
            stagedPath: staged.path,
            stagedMode: (stagedAttributes[.posixPermissions] as? Int) ?? -1,
            scratchMode: (attributes(staged.deletingLastPathComponent())[.posixPermissions] as? Int) ?? -1,
            sameVolume: (stagedAttributes[.systemNumber] as? Int) != nil
                && (stagedAttributes[.systemNumber] as? Int) == (attributes(destination.deletingLastPathComponent())[.systemNumber] as? Int),
            stagedVersion: version, stagedIds: ids,
            destinationBytes: try? Data(contentsOf: destination))
    }
}

/// Shared arrange and read helpers.
private enum Worf497 {
    static let addProbe = Migration(version: 2) { db in try db.execute(sql: "CREATE TABLE probe (id INTEGER)") }

    static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-worf497-\(UUID().uuidString)")
    }

    static func ids(_ strings: [String]) -> Set<Int> { Set(strings.map { Int(String($0.suffix(12)))! }) }

    /// What is inside one file, read from a private copy of that file alone (no `-wal` beside it).
    static func read(fileAlone url: URL) throws -> (version: Int, ids: Set<Int>, integrity: [String]) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-worf497-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("only.sqlite")
        try FileManager.default.copyItem(at: url, to: copy)
        return try DatabaseQueue(path: copy.path).read { db in
            (try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1,
             ids(try String.fetchAll(db, sql: "SELECT id FROM item")),
             try String.fetchAll(db, sql: "PRAGMA integrity_check"))
        }
    }

    /// The live database as any reader sees it (main file plus `-wal`).
    static func readLive(root: URL) throws -> (version: Int, ids: Set<Int>, hasProbeTable: Bool) {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: root.appendingPathComponent(FlotsamDatabase.fileName).path, configuration: configuration).read { db in
            (try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1,
             ids(try String.fetchAll(db, sql: "SELECT id FROM item")),
             try Bool.fetchOne(db, sql: "SELECT count(*) > 0 FROM sqlite_master WHERE name = 'probe'") ?? false)
        }
    }

    static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    static func names(in url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }

    /// Holds a read transaction on its own connection until `release()` (blocks every checkpoint past its snapshot).
    final class HeldReader: @unchecked Sendable {
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

    /// A version-1 library with items 1...3, closed cleanly, plus the user's own files around the copy.
    static func seededLibrary(root: URL) async throws {
        let first = try await Store.make(root: root)
        try await first.insert((1...3).map { Spec(n: $0, ageMs: hourMs) })
        let preMigration = root.appendingPathComponent("pre-migration")
        try FileManager.default.createDirectory(at: preMigration, withIntermediateDirectories: true)
        try Data("earlier copy".utf8).write(to: preMigration.appendingPathComponent("flotsam-v1.sqlite"))
        try Data("the user's note".utf8).write(to: preMigration.appendingPathComponent("notes.txt"))
        let blob = root.appendingPathComponent("blobs/zz")
        try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: true)
        try Data("blob".utf8).write(to: blob.appendingPathComponent("keep.bin"))
    }
}

@Suite struct Worf497PreMigrationCopyTests {
    /// OC-WORF497-01 / AC-007-22. Given a reader holding a snapshot at items 1 to 3 and 200 further items (about 400 KB)
    /// committed after it, so they live only in `-wal`, when the open migrates 1 to 2, then the copy read alone holds
    /// all 203 items at user_version 1 and passes integrity_check, and at the moment it was published it was already
    /// whole. Red under M1 (the main file alone lacks the 200) and M3 (an empty file is published).
    @Test("OC-WORF497-01 held reader: copy holds every committed row, including those after the reader's snapshot")
    func heldReaderCopyHasEveryRow() async throws {
        let root = Worf497.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let first = try await Store.make(root: root)
            try await first.insert((1...3).map { Spec(n: $0, ageMs: hourMs) })
        }
        let reader = try Worf497.HeldReader(path: root.appendingPathComponent(FlotsamDatabase.fileName).path)
        let writer = try await Store.make(root: root)
        let text = String(repeating: "x", count: 2_000)
        try await writer.insert((4...203).map { Spec(n: $0, ageMs: hourMs, text: "\(text) \($0)") })
        let mainAlone = try Worf497.read(fileAlone: root.appendingPathComponent(FlotsamDatabase.fileName))
        try #require(mainAlone.ids.count < 203, "fixture is not WAL-resident: the main file already holds every item")
        // And the reader really does block a checkpoint (busy = 1), so this is the situation the ticket describes.
        var quick = Configuration()
        quick.busyMode = .timeout(0.1)
        let prober = try DatabaseQueue(path: root.appendingPathComponent(FlotsamDatabase.fileName).path, configuration: quick)
        let busy = try await prober.writeWithoutTransaction { db in
            try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")?[0] as Int64?
        }
        try prober.close()
        try #require(busy == 1, "the held reader does not block the checkpoint")

        let fileSystem = Worf497FileSystem()
        let upgraded = try await FlotsamDatabase.open(
            folder: root, fileSystem: fileSystem, migrations: Migrations.all + [Worf497.addProbe], busyTimeout: 0.3).get()
        reader.release()

        let copy = try Worf497.read(fileAlone: root.appendingPathComponent("pre-migration/flotsam-v1.sqlite"))
        #expect(copy.version == 1)
        #expect(copy.ids == Set(1...203))
        #expect(copy.integrity == ["ok"])
        let published = fileSystem.publishes.value
        #expect(published.count == 1)
        #expect(published.first?.stagedIds == Set(1...203), "the copy was not whole when it was moved into place")
        #expect(published.first?.stagedVersion == 1)
        #expect(try await upgraded.diagnostics().get().userVersion == 2)
        withExtendedLifetime(writer) {}
    }

    /// OC-WORF497-02 / AC-007-22. Given a second connection that commits items 4 and 5 at the moment the copy is built
    /// and not yet in place (after the backup, before the rename), when the open migrates, then the copy holds exactly
    /// the items that were committed when it was taken (1 to 3), is integrity_check clean, and the live database ends
    /// with all five at version 2. Red if the copy is taken later than the snapshot (reads the live file at publish) or
    /// is torn by the concurrent commit.
    /// Not modelled here: a writer holding an open write transaction across the whole open. That blocks the open itself
    /// (pool setup, before any copy) for the busy timeout, which AC-007-21 already pins.
    @Test("OC-WORF497-02 a writer committing during the copy leaves a consistent copy")
    func writerInFlightLeavesConsistentCopy() async throws {
        let root = Worf497.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Worf497.seededLibrary(root: root)
        var writerConfiguration = Configuration()
        writerConfiguration.busyMode = .timeout(5)
        let writerQueue = try DatabaseQueue(
            path: root.appendingPathComponent(FlotsamDatabase.fileName).path, configuration: writerConfiguration)
        let fileSystem = Worf497FileSystem()
        fileSystem.beforePublish.value = {
            try? writerQueue.write { db in
                for n in 4...5 {
                    try db.execute(
                        sql: """
                            INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize,
                                              pinned, updatedAt) VALUES (?, 'text', 1, 1, ?, 'late', 'late', 0, 0, 1)
                            """,
                        arguments: [Store.id(n).uuidString, "key-\(n)"])
                }
            }
        }

        let upgraded = try await FlotsamDatabase.open(
            folder: root, fileSystem: fileSystem, migrations: Migrations.all + [Worf497.addProbe], busyTimeout: 5).get()

        let copy = try Worf497.read(fileAlone: root.appendingPathComponent("pre-migration/flotsam-v1.sqlite"))
        #expect(copy.version == 1)
        #expect(copy.ids == [1, 2, 3])
        #expect(copy.integrity == ["ok"])
        let live = try Worf497.readLive(root: root)
        #expect(live.version == 2)
        #expect(live.ids == [1, 2, 3, 4, 5], "the concurrent commit was lost, so the fixture did not run")
        _ = upgraded
    }

    /// OC-WORF497-03 / AC-007-22. Given a second connection committing pairs of items continuously while the open takes
    /// its copy, then whatever the interleaving the copy is integrity_check clean, holds items 1 to 3 and only whole
    /// pairs, with no gap in the numbering. Invariant-based: it cannot pass if the copy is torn or reads two snapshots.
    @Test("OC-WORF497-03 a continuously committing writer never produces a torn copy")
    func continuousWriterNeverTearsTheCopy() async throws {
        let root = Worf497.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Worf497.seededLibrary(root: root)
        let writer = try await Store.make(root: root)
        let stop = Cell(false)
        let committed = Cell(0)
        let load = Task.detached {
            var n = 4
            while !stop.value {
                if (try? await writer.insert([Spec(n: n, ageMs: hourMs), Spec(n: n + 1, ageMs: hourMs)])) != nil {
                    committed.value = n + 1
                    n += 2
                }
            }
        }
        while committed.value < 12 { try await Task.sleep(nanoseconds: 2_000_000) }

        _ = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.all + [Worf497.addProbe], busyTimeout: 5).get()
        stop.value = true
        await load.value

        let copy = try Worf497.read(fileAlone: root.appendingPathComponent("pre-migration/flotsam-v1.sqlite"))
        #expect(copy.integrity == ["ok"])
        #expect(copy.version == 1)
        #expect(copy.ids.isSuperset(of: [1, 2, 3]))
        #expect(copy.ids.count >= 12, "the load was not running when the copy was taken")
        #expect(copy.ids == Set(1...copy.ids.count), "gap in the numbering: the copy is not one snapshot")
        #expect(copy.ids.count % 2 == 1, "half a pair is in the copy (items 1 to 3 plus whole pairs is always odd)")
    }

    /// OC-WORF497-04 / AC-007-22. Given a fault at each step of the copy (scratch create, staged create, backup into a
    /// destination that is not a database, backup into a read-only destination, publish), when the open runs, then it
    /// fails with STO-DB-003, `pre-migration/` holds exactly the earlier copy (same bytes) and the user's note, no scratch
    /// directory is left, nothing outside the scratch directory was removed, the live database is untouched at version
    /// 1 with items 1 to 3, and a later open without the fault succeeds with a complete copy. Red under M2 (the backup
    /// error swallowed, the garbage published), M5 (scratch left) and M6 (earlier copy removed first).
    @Test("OC-WORF497-04 a failed copy is STO-DB-003 and leaves nothing partial, nothing deleted, nothing migrated",
          arguments: [Worf497FileSystem.Fault.scratchCreate, .stagedWrite, .backupNotADatabase, .backupReadOnly, .publish])
    fileprivate func failedCopyLeavesNothing(fault: Worf497FileSystem.Fault) async throws {
        let root = Worf497.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Worf497.seededLibrary(root: root)
        let fileSystem = Worf497FileSystem(fault: fault)

        let result = await FlotsamDatabase.open(
            folder: root, fileSystem: fileSystem, migrations: Migrations.all + [Worf497.addProbe], busyTimeout: 0.3)

        guard case .failure(let error) = result else { Issue.record("\(fault): the open succeeded without a pre-migration copy"); return }
        #expect(error.code == .stoDb003, "\(fault)")
        let folder = root.appendingPathComponent("pre-migration")
        #expect(Worf497.names(in: folder) == ["flotsam-v1.sqlite", "notes.txt"], "\(fault)")
        #expect(try String(contentsOf: folder.appendingPathComponent("flotsam-v1.sqlite"), encoding: .utf8) == "earlier copy", "\(fault)")
        #expect(try String(contentsOf: folder.appendingPathComponent("notes.txt"), encoding: .utf8) == "the user's note", "\(fault)")
        #expect(Worf497.names(in: root.appendingPathComponent("tmp")).filter { $0.hasPrefix("premigration-") }.isEmpty, "\(fault)")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs/zz/keep.bin").path), "\(fault)")
        let tmpPath = root.appendingPathComponent("tmp").resolvingSymlinksInPath().path
        for path in fileSystem.removed.value {
            #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(tmpPath + "/premigration-"), "removed outside scratch: \(path)")
        }
        let live = try Worf497.readLive(root: root)
        #expect(live.version == 1, "\(fault)")
        #expect(live.ids == [1, 2, 3], "\(fault)")
        #expect(live.hasProbeTable == false, "\(fault)")

        let retry = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.all + [Worf497.addProbe], busyTimeout: 0.3).get()
        #expect(try await retry.diagnostics().get().userVersion == 2)
        let copy = try Worf497.read(fileAlone: folder.appendingPathComponent("flotsam-v1.sqlite"))
        #expect(copy.ids == [1, 2, 3], "\(fault)")
        #expect(copy.version == 1, "\(fault)")
    }

    /// OC-WORF497-05 / AC-007-22. Given a successful migration over an earlier stale copy, then the copy is staged in a
    /// scratch directory inside `tmp/` created 0700, the staged file is created with permission argument 0600 and is
    /// 0600 when it is moved into place, the scratch and the destination folder are on the same volume (so the rename is
    /// one atomic step), the earlier copy was still there byte for byte at the moment of publishing, the staging comes
    /// before the publish, the copy ends 0600 with no `-wal`, `-shm` or `-journal` beside it, and the scratch is gone.
    /// Red under M4 (mode), M5 (scratch left), M6 (earlier copy removed early) and M7 (scratch off the volume).
    @Test("OC-WORF497-05 staged 0600 in tmp/, same volume, published whole, earlier copy untouched until then, scratch removed")
    func stagingPermissionsVolumeOrderAndCleanup() async throws {
        let root = Worf497.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Worf497.seededLibrary(root: root)
        let fileSystem = Worf497FileSystem()

        let upgraded = try await FlotsamDatabase.open(
            folder: root, fileSystem: fileSystem, migrations: Migrations.all + [Worf497.addProbe], busyTimeout: 0.3).get()

        let writes = fileSystem.writes.value
        #expect(writes.count == 1)
        #expect(writes.first?.permissions == 0o600)
        #expect(writes.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent } == "tmp")
        let published = fileSystem.publishes.value
        try #require(published.count == 1)
        #expect(published[0].stagedMode == 0o600)
        #expect(published[0].scratchMode == 0o700)
        #expect(published[0].sameVolume)
        #expect(published[0].stagedIds == [1, 2, 3])
        #expect(published[0].destinationBytes == Data("earlier copy".utf8), "the earlier copy was removed before the new one was whole")
        let events = fileSystem.events.value
        let stage = events.firstIndex { $0.hasPrefix("stage ") }
        let publish = events.firstIndex { $0.hasPrefix("publish ") }
        #expect(stage != nil && publish != nil && stage! < publish!)
        #expect(Worf497.mode(root.appendingPathComponent("pre-migration/flotsam-v1.sqlite")) == 0o600)
        #expect(Worf497.names(in: root.appendingPathComponent("pre-migration")) == ["flotsam-v1.sqlite", "notes.txt"])
        #expect(Worf497.names(in: root.appendingPathComponent("tmp")).filter { $0.hasPrefix("premigration-") }.isEmpty)
        #expect(try await upgraded.diagnostics().get().userVersion == 2)
    }

    /// OC-WORF497-06 / AC-007-22. Given a copy name taken by a folder (the user's), when the open migrates, then the
    /// copy lands under `flotsam-v1-1.sqlite`, complete, 0600, and the folder and what is in it is untouched: the
    /// atomic publish never replaces a non-file.
    @Test("OC-WORF497-06 a folder on the copy's name is never replaced by the publish")
    func folderOnCopyNameIsLeftAlone() async throws {
        let root = Worf497.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await Store.make(root: root)
        try await first.insert((1...3).map { Spec(n: $0, ageMs: hourMs) })
        let occupied = root.appendingPathComponent("pre-migration/flotsam-v1.sqlite")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: occupied.appendingPathComponent("mine.txt"))
        _ = first

        _ = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.all + [Worf497.addProbe], busyTimeout: 0.3).get()

        #expect(try String(contentsOf: occupied.appendingPathComponent("mine.txt"), encoding: .utf8) == "inside")
        let copy = try Worf497.read(fileAlone: root.appendingPathComponent("pre-migration/flotsam-v1-1.sqlite"))
        #expect(copy.ids == [1, 2, 3])
        #expect(Worf497.mode(root.appendingPathComponent("pre-migration/flotsam-v1-1.sqlite")) == 0o600)
    }
}
