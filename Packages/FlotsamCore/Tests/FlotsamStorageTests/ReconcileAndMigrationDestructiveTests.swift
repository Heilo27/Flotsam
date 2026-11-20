import CryptoKit
import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T batch 1, reconcile (FR-007-13) and pre-migration pruning (FR-007-17). Each test plants foreign files next
// to the Flotsam-named ones and asserts the foreign ones survive; a stat or listing failure is injected through the
// FileSystemPort and must never be read as "missing".

private let tenMinMs: Int64 = 10 * 60_000

@Suite struct ReconcileDestructiveTests {
    /// OC-7024. Given orphan blobs (no row) aged 9 min and 11 min and a referenced blob, when reconcile runs, then only the
    /// 11 minute orphan is removed.
    @Test func oc7024_orphanBlobGraceIsTenMinutes() async throws {
        let s = try await Store.make(migrations: Migrations.baseline)
        defer { s.cleanUp() }
        try await s.insert(Spec(n: 1, ageMs: hourMs, blobs: 1, repBytes: 10))
        try s.plantOrphanBlob(101, ageMs: 9 * 60_000)
        try s.plantOrphanBlob(102, ageMs: 11 * 60_000)

        let outcome = try await s.database.reconcile().get()

        #expect(outcome.orphanBlobsRemoved == 1)
        #expect(s.exists(s.blobURL(101, 1)))
        #expect(!s.exists(s.blobURL(102, 1)))
        #expect(s.exists(s.blobURL(1, 1)))
        #expect(try s.presentIds() == [1])
    }

    /// OC-7112. Given item A (text, two representations whose blobs are gone), item B (an image whose only blob is gone)
    /// and item F (files kind, no representations, one member), when reconcile runs, then three representation rows are
    /// removed, only B is removed as an item, A keeps its text and F is untouched.
    @Test func oc7112_missingBlobRowsRemovedAndOnlyContentlessItemsDropped() async throws {
        let s = try await Store.make()
        defer { s.cleanUp() }
        var f = Spec(n: 3, kind: .file, ageMs: hourMs)
        f.members = [("/tmp/flotsam-never-checked.txt", false)]
        try await s.insert([
            Spec(n: 1, ageMs: hourMs, blobs: 2, repBytes: 10, text: "keep my text"),
            Spec(n: 2, kind: .image, ageMs: hourMs, blobs: 1, repBytes: 10),
            f,
            Spec(n: 4, ageMs: hourMs, blobs: 1, repBytes: 10),
        ])
        for (n, ordinal) in [(1, 1), (1, 2), (2, 1)] { try FileManager.default.removeItem(at: s.blobURL(n, ordinal)) }

        let outcome = try await s.database.reconcile().get()

        #expect(outcome.missingBlobRowsRemoved == 3)
        #expect(outcome.itemsRemoved == 1)
        #expect(try s.presentIds() == [1, 3, 4])
        #expect(try s.representationCount(1) == 0)
        #expect(try s.representationCount(4) == 1)
        #expect(try s.count("bundleMember") == 1)
    }

    /// OC-7114. Given orphan thumbnails (old), and foreign files in thumbs/ and blobs/ (a readme, a name that is not a
    /// UUID, a .bak copy of a Flotsam name, a Flotsam-looking name with no ordinal), when reconcile runs, then the orphan
    /// thumbnails go and every foreign file survives with its contents.
    @Test func oc7114_orphanThumbnailsGoAndForeignFilesSurvive() async throws {
        let s = try await Store.make(migrations: Migrations.baseline)
        defer { s.cleanUp() }
        try await s.insert(Spec(n: 1, ageMs: hourMs, blobs: 1, repBytes: 10, thumbs: true))
        let old = 3 * hourMs
        let orphanThumb = try s.plant("thumbs/\(Store.id(200).uuidString)-256.jpg", contents: "t", ageMs: old)
        let orphanThumb2 = try s.plant("thumbs/\(Store.id(200).uuidString)-512.jpg", contents: "t", ageMs: old)
        let foreign = [
            try s.plant("thumbs/readme.txt", ageMs: old),
            try s.plant("thumbs/not-a-uuid-256.jpg", ageMs: old),
            try s.plant("thumbs/\(Store.id(201).uuidString)-256.jpg.bak", ageMs: old),
            try s.plant("blobs/00/notes.txt", ageMs: old),
            try s.plant("blobs/00/\(Store.id(202).uuidString)", ageMs: old),
            try s.plant("blobs/00/\(Store.id(203).uuidString).1.bak", ageMs: old),
            try s.plant("blobs/readme-at-root.txt", ageMs: old),
        ]

        let outcome = try await s.database.reconcile().get()

        #expect(outcome.orphanThumbnailsRemoved == 2)
        #expect(!s.exists(orphanThumb) && !s.exists(orphanThumb2))
        #expect(foreign.allSatisfy { s.exists($0) })
        #expect(foreign.allSatisfy { s.contents($0) == "foreign" })
        #expect(s.exists(s.thumbURL(1, 256)) && s.exists(s.thumbURL(1, 512)))
        #expect(s.exists(s.blobURL(1, 1)))
    }

    // MARK: Un-inspectable files are never judged missing or orphaned

    private func arrangeMissingRowAndOrphan(_ s: Store) async throws {
        try await s.insert([
            Spec(n: 1, kind: .image, ageMs: hourMs, blobs: 1, repBytes: 10),  // blob removed below: truly missing
            Spec(n: 2, kind: .image, ageMs: hourMs, blobs: 1, repBytes: 10),  // blob present
        ])
        try FileManager.default.removeItem(at: s.blobURL(1, 1))
        try s.plantOrphanBlob(300, ageMs: 2 * hourMs)
    }

    /// OC-7113-adjacent (FR-007-13 stat rule). Given a listed blob file for which stat fails, when reconcile runs, then no
    /// missing-blob repair happens (both items and rows remain, including the truly missing one) and the un-inspectable
    /// old orphan is not deleted.
    @Test func statFailureOnListedFileSkipsRepairAndNeverCountsAsOrphan() async throws {
        var faulty = FaultyFileSystem()
        let unstatable = Store.id(300).uuidString + ".1"
        faulty.failInfo = { $0.lastPathComponent == unstatable }
        let s = try await Store.make(fileSystem: faulty, migrations: Migrations.baseline)
        defer { s.cleanUp() }
        try await arrangeMissingRowAndOrphan(s)

        let outcome = try await s.database.reconcile().get()

        #expect(outcome.missingBlobRowsRemoved == 0)
        #expect(outcome.itemsRemoved == 0)
        #expect(outcome.orphanBlobsRemoved == 0)
        #expect(try s.presentIds() == [1, 2])
        #expect(try s.representationCount(1) == 1)
        #expect(s.exists(s.blobURL(300, 1)))
    }

    /// Same rule, stat failing on a referenced blob that does exist. Given item 2's blob cannot be stat'ed, when reconcile
    /// runs, then item 2 is not treated as missing and item 1's missing row is also left alone.
    @Test func statFailureOnReferencedBlobIsNotTreatedAsMissing() async throws {
        var faulty = FaultyFileSystem()
        let unstatable = Store.id(2).uuidString + ".1"
        faulty.failInfo = { $0.lastPathComponent == unstatable }
        let s = try await Store.make(fileSystem: faulty, migrations: Migrations.baseline)
        defer { s.cleanUp() }
        try await arrangeMissingRowAndOrphan(s)

        _ = await s.database.reconcile()

        #expect(try s.presentIds() == [1, 2])
        #expect(try s.representationCount(2) == 1)
        #expect(try s.representationCount(1) == 1)
        #expect(s.exists(s.blobURL(2, 1)))
    }

    /// Given a shard directory whose listing fails, when reconcile runs, then no row is removed as missing and the orphan in
    /// that shard is not deleted.
    @Test func unreadableShardListingSkipsRepair() async throws {
        var faulty = FaultyFileSystem()
        faulty.failList = { $0.lastPathComponent == "00" }
        let s = try await Store.make(fileSystem: faulty, migrations: Migrations.baseline)
        defer { s.cleanUp() }
        try await arrangeMissingRowAndOrphan(s)

        _ = await s.database.reconcile()

        #expect(try s.presentIds() == [1, 2])
        #expect(try s.representationCount(1) == 1)
        #expect(s.exists(s.blobURL(300, 1)))
    }

    /// Given the blobs root itself cannot be listed, when reconcile runs, then every row and item stays and the orphan
    /// stays (an unreadable folder is not an empty folder).
    @Test func unreadableBlobsRootNeverEmptiesTheDatabase() async throws {
        var faulty = FaultyFileSystem()
        faulty.failList = { $0.lastPathComponent == "blobs" }
        let s = try await Store.make(fileSystem: faulty, migrations: Migrations.baseline)
        defer { s.cleanUp() }
        try await arrangeMissingRowAndOrphan(s)

        _ = await s.database.reconcile()

        #expect(try s.presentIds() == [1, 2])
        #expect(try s.representationCount(1) == 1 && s.representationCount(2) == 1)
        #expect(s.exists(s.blobURL(300, 1)))
        #expect(s.exists(s.blobURL(2, 1)))
    }

    // MARK: Quarantine (OC-7110 / OC-7111)

    private func corruptRoot() throws -> (root: URL, garbage: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("blobs/00"), withIntermediateDirectories: true)
        let garbage = Data(String(repeating: "this is not a sqlite database. ", count: 200).utf8)
        try garbage.write(to: root.appendingPathComponent("flotsam.sqlite"))
        try Data("blob".utf8).write(to: root.appendingPathComponent("blobs/00/\(Store.id(1).uuidString).1"))
        return (root, garbage)
    }

    private func quarantined(_ root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("corrupt-") }.map { root.appendingPathComponent($0) }
    }

    /// OC-7110. Given a garbage flotsam.sqlite and a blob, when the database opens, then the damaged file is moved into one
    /// corrupt-<timestamp>/ folder byte-for-byte, a fresh version-1 database with no items is created, and the open notice
    /// is STO-DB-002.
    @Test func oc7110_damagedDatabaseIsMovedAsideNotDeleted() async throws {
        let (root, garbage) = try corruptRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try await FlotsamDatabase.openBaseline(folder: root).get()

        let folders = quarantined(root)
        #expect(folders.count == 1)
        let moved = try folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
        #expect(moved.contains { (try? Data(contentsOf: $0)) == garbage })
        #expect(database.openNotice?.code == .stoDb002)
        let diagnostics = try await database.pragmaFacts()
        #expect(diagnostics.userVersion == 1)
        let store = Store(root: root, clock: ManualClock(), database: database)
        #expect(try store.count("item") == 0)
    }

    /// OC-7110. Given a garbage database and K=3 blobs in three shard folders, when the database opens, then all 3 blobs
    /// sit byte-for-byte under corrupt-<timestamp>/blobs and the live blobs/ folder exists again with no file in it.
    @Test("OC-7110 quarantine moves every blob aside and leaves an empty blobs folder")
    func oc7110_quarantineMovesBlobsAside() async throws {
        // given a damaged database and three blobs
        let (root, _) = try corruptRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs: [(path: String, bytes: Data)] = [
            ("a1/blob-a", Data("alpha-bytes".utf8)), ("ff/blob-b", Data("bravo-bytes-longer".utf8)), ("07/blob-c", Data([0, 1, 2, 253, 254, 255])),
        ]
        for blob in blobs {
            let url = root.appendingPathComponent("blobs/\(blob.path)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try blob.bytes.write(to: url)
        }

        // when the database opens
        _ = try await FlotsamDatabase.openBaseline(folder: root).get()

        // then the three blobs are under the quarantine folder, identical, and blobs/ is empty again
        let folder = try #require(quarantined(root).first)
        #expect(quarantined(root).count == 1)
        for blob in blobs {
            #expect(try Data(contentsOf: folder.appendingPathComponent("blobs/\(blob.path)")) == blob.bytes)
        }
        let movedFiles = filesUnder(folder.appendingPathComponent("blobs"))
        #expect(movedFiles == ["00/\(Store.id(1).uuidString).1", "07/blob-c", "a1/blob-a", "ff/blob-b"])
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(filesUnder(root.appendingPathComponent("blobs")).isEmpty)
    }

    private func filesUnder(_ directory: URL) -> [String] {
        let base = directory.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var names: [String] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            names.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)))
        }
        return names.sorted()
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// OC-7110 / OC-7111. Given a real database whose file still opens (header and schema intact) but one non-root table
    /// leaf page has its rows out of order so PRAGMA quick_check reports rows, with a -wal and a -shm beside it, when the
    /// database opens, then the database file and the -wal move into one corrupt-<timestamp>/ folder with the SHA-256 they
    /// had before the open (FR-007-13, TASK-370), the -shm moves with them, a fresh empty version-1 database is created,
    /// and the open notice is STO-DB-002. The -shm is SQLite's wal-index, rebuilt from the -wal and updated in place by
    /// every connection, so only its presence is asserted.
    @Test("OC-7110 a database that opens but fails quick_check is quarantined and replaced")
    func oc7110_quickCheckFailureIsQuarantined() async throws {
        // given 400 rows spread over many pages, closed and checkpointed
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-leaf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try await Store.make(root: root, migrations: Migrations.baseline)
        let padding = String(repeating: "x", count: 200)
        try await seeded.insert((1...400).map { Spec(n: $0, text: "m96-row-\($0)-\(padding)") })
        let pageSize = try await seeded.database.pool.read { try Int.fetchOne($0, sql: "PRAGMA page_size")! }
        try await seeded.database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try seeded.database.pool.close()

        // and one table leaf page (type byte 0x0D, holding row text, not page 1) has its first two cell pointers swapped
        let file = root.appendingPathComponent("flotsam.sqlite")
        var bytes = try Data(contentsOf: file)
        let marker = Data("m96-row-".utf8)
        let pageCount = bytes.count / pageSize
        let leaf = try #require((2...pageCount).first { page in
            let start = (page - 1) * pageSize
            return bytes[start] == 0x0D && bytes.subdata(in: start..<(start + pageSize)).range(of: marker) != nil
        })
        // swap its first two cell pointers: the b-tree is still readable, but its rows are out of order
        let pointers = (leaf - 1) * pageSize + 8
        let first = bytes.subdata(in: pointers..<(pointers + 2))
        let second = bytes.subdata(in: (pointers + 2)..<(pointers + 4))
        #expect(first != second)
        bytes.replaceSubrange(pointers..<(pointers + 2), with: second)
        bytes.replaceSubrange((pointers + 2)..<(pointers + 4), with: first)
        try bytes.write(to: file)
        // the premise: the damage is invisible to a plain open and only quick_check reports it
        var readOnly = Configuration()
        readOnly.readonly = true
        let probe = try DatabaseQueue(path: file.path, configuration: readOnly)
        let check = try await probe.read { try String.fetchAll($0, sql: "PRAGMA quick_check") }
        #expect(check != ["ok"])
        #expect(!check.isEmpty)
        try probe.close()

        // and a -wal (no valid header, so SQLite reads it as empty) and a -shm sit beside it; the hashes are taken last
        let wal = root.appendingPathComponent("flotsam.sqlite-wal")
        try Data(repeating: 0xAB, count: 64).write(to: wal)
        try Data(repeating: 0xCD, count: 32_768).write(to: root.appendingPathComponent("flotsam.sqlite-shm"))
        let databaseHash = try sha256(file)
        let walHash = try sha256(wal)

        // when the database opens
        let database = try await FlotsamDatabase.openBaseline(folder: root).get()

        // then the damaged bytes are preserved exactly in one quarantine folder and a fresh database is live
        let folders = quarantined(root)
        #expect(folders.count == 1)
        let folder = try #require(folders.first)
        #expect(try sha256(folder.appendingPathComponent("flotsam.sqlite")) == databaseHash)
        #expect(try sha256(folder.appendingPathComponent("flotsam.sqlite-wal")) == walHash)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("flotsam.sqlite-shm").path))
        #expect(database.openNotice?.code == .stoDb002)
        let diagnostics = try await database.pragmaFacts()
        #expect(diagnostics.userVersion == 1)
        let fresh = Store(root: root, clock: ManualClock(), database: database)
        #expect(try fresh.count("item") == 0)
    }

    /// OC-7111. Given a quarantine folder, when Clear History, a retention sweep, a reconcile and a reopen all run, then the
    /// folder and its bytes are untouched by every one of them.
    @Test func oc7111_quarantineFolderSurvivesEveryDeletePathAndReopen() async throws {
        let (root, garbage) = try corruptRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await FlotsamDatabase.openBaseline(folder: root).get()
        let folder = try #require(quarantined(root).first)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(!before.isEmpty)

        _ = try await database.clearHistory(range: .allTime, includeExempt: true).get()
        _ = try await database.runRetentionSweep(preset: .d7, budget: .mib500).get()
        _ = try await database.reconcile().get()
        _ = try await FlotsamDatabase.openBaseline(folder: root).get()

        #expect(quarantined(root) == [folder])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
        let moved = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(moved.contains { (try? Data(contentsOf: $0)) == garbage })
    }
}

@Suite struct PreMigrationDestructiveTests {
    private struct Boom: Error {}

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-mig-\(UUID().uuidString)")
    }

    /// Opens `url` read-only on its own connection and returns (user_version, item count); nil items if no item table.
    private func snapshot(_ url: URL) throws -> (version: Int, items: Int?, hasProbe: Bool) {
        // Inspect a private copy (with its WAL, if any) so a read never touches the file under test.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("snap.sqlite")
        try FileManager.default.copyItem(at: url, to: copy)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            try FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        }
        let queue = try DatabaseQueue(path: copy.path)
        return try queue.read { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            let items = tables.contains("item") ? try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") : nil
            return (version, items, tables.contains("probe"))
        }
    }

    /// Creates a version-1 database with three items and closes it, as if the app had quit.
    private func makeVersionOne(_ root: URL) async throws {
        let first = try await Store.make(root: root, migrations: Migrations.baseline)
        try await first.insert((1...3).map { Spec(n: $0, ageMs: hourMs) })
    }

    private let addProbe = Migration(version: 2) { db in try db.execute(sql: "CREATE TABLE probe (id INTEGER)") }

    /// OC-7134. Given a version-1 database with 3 items and a release that adds migration 2, when it opens, then
    /// pre-migration/flotsam-v1.sqlite is a version-1 copy with 3 items and the live database is version 2 with 3 items.
    @Test func oc7134_copyIsTakenBeforeMigratingAndIsAtTheOldVersion() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVersionOne(root)

        let upgraded = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.baseline + [addProbe]).get()

        let copy = try snapshot(root.appendingPathComponent("pre-migration/flotsam-v1.sqlite"))
        #expect(copy.version == 1)
        #expect(copy.items == 3)
        #expect(!copy.hasProbe)
        let live = try await upgraded.pragmaFacts()
        #expect(live.userVersion == 2)
        #expect(try Store(root: root, clock: ManualClock(), database: upgraded).count("item") == 3)
    }

    /// OC-7137. Given Flotsam-named leftovers (flotsam-v0.sqlite and its -wal and -shm, and flotsam-v7.sqlite-wal) and
    /// foreign names that merely resemble them, when a migration copy is taken, then the Flotsam-named leftovers are
    /// pruned, every foreign name survives with its contents, and the folder holds exactly the new copy plus the foreign set.
    @Test func oc7137_pruningTouchesOnlyFlotsamNamedFiles() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVersionOne(root)
        let folder = root.appendingPathComponent("pre-migration")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pruned = ["flotsam-v0.sqlite", "flotsam-v0.sqlite-wal", "flotsam-v0.sqlite-shm", "flotsam-v7.sqlite-wal"]
        let foreign = [
            "notes.txt", "flotsam-v1.sqlite.bak", "flotsam-vx.sqlite", "flotsam-v.sqlite",
            "flotsam-v\u{0661}.sqlite", "flotsam-v99999999999999999999.sqlite", "my-flotsam-v2.sqlite",
        ]
        for name in pruned + foreign { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }

        _ = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.baseline + [addProbe]).get()

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(remaining == Set(["flotsam-v1.sqlite"] + foreign))
        #expect(foreign.allSatisfy { (try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8)) == $0 })
    }

    /// TASK-422 D1 (older prune). Given a DIRECTORY named like an older copy (with a file inside) and a link named like
    /// a copy's -wal, when a migration copy is taken, then both survive: only regular files Flotsam named are pruned,
    /// the same rule the Clear History purge uses. Red if the prune goes back to a name-only test.
    @Test func pruningNeverRemovesADirectoryOrLinkNamedLikeACopy() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVersionOne(root)
        let folder = root.appendingPathComponent("pre-migration")
        let lookalikeDir = folder.appendingPathComponent("flotsam-v0.sqlite")
        try FileManager.default.createDirectory(at: lookalikeDir, withIntermediateDirectories: true)
        let inner = lookalikeDir.appendingPathComponent("user-notes.txt")
        try Data("keep".utf8).write(to: inner)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let link = folder.appendingPathComponent("flotsam-v7.sqlite-wal")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        _ = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.baseline + [addProbe]).get()

        #expect(FileManager.default.fileExists(atPath: inner.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    /// TASK-422 D1 (occupied name, folder). Given a folder named exactly like the new copy (with a file inside), when a
    /// migration copy is taken, then the folder and its file survive, the open succeeds and the copy lands as
    /// flotsam-v1-1.sqlite, a name the shared rule recognises (so a later prune or purge covers it).
    @Test func anOccupyingFolderIsKeptAndTheCopyLandsUnderAnotherName() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVersionOne(root)
        let folder = root.appendingPathComponent("pre-migration")
        let occupant = folder.appendingPathComponent("flotsam-v1.sqlite")
        try FileManager.default.createDirectory(at: occupant, withIntermediateDirectories: true)
        let inner = occupant.appendingPathComponent("user-notes.txt")
        try Data("keep".utf8).write(to: inner)

        _ = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.baseline + [addProbe]).get()

        #expect(try String(contentsOf: inner, encoding: .utf8) == "keep")
        let copy = folder.appendingPathComponent("flotsam-v1-1.sqlite")
        var isDirectory: ObjCBool = true
        #expect(FileManager.default.fileExists(atPath: copy.path, isDirectory: &isDirectory) && !isDirectory.boolValue)
        #expect(DataFolder.isPreMigrationCopyFile(named: "flotsam-v1-1.sqlite"))
        #expect(DataFolder.isPreMigrationCopyFile(named: "flotsam-v1-1.sqlite-wal"))
        #expect(!DataFolder.isPreMigrationCopyFile(named: "flotsam-v1-.sqlite"))
        #expect(!DataFolder.isPreMigrationCopyFile(named: "flotsam-v1-1-1.sqlite"))
    }

    /// TASK-422 D1 (occupied name, link). Given a link named exactly like the new copy, pointing at a file outside, when
    /// a migration copy is taken, then the link and its target are untouched (nothing is written through the link)
    /// and the copy lands as flotsam-v1-1.sqlite.
    @Test func anOccupyingLinkIsKeptAndItsTargetUntouched() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVersionOne(root)
        let folder = root.appendingPathComponent("pre-migration")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: target)
        let link = folder.appendingPathComponent("flotsam-v1.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        _ = try await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.baseline + [addProbe]).get()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "outside")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("flotsam-v1-1.sqlite").path))
    }

    /// OC-7138. Given a current-version database with items, when it reopens with nothing pending, then no copy is taken
    /// and the items are unchanged.
    @Test func oc7138_reopenWithNothingPendingTakesNoCopy() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVersionOne(root)

        let reopened = try await FlotsamDatabase.openBaseline(folder: root).get()

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pre-migration").path))
        let store = Store(root: root, clock: ManualClock(), database: reopened)
        #expect(try store.presentIds() == [1, 2, 3])
    }

    /// OC-7135. Given a database whose user_version is 99 (newer than this build), when it opens, then the open fails with
    /// STO-DB-003, the file is byte-identical and no WAL or shared-memory file is created.
    @Test func oc7135_newerDatabaseIsRefusedAndLeftByteIdentical() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("flotsam.sqlite")
        do {
            let queue = try DatabaseQueue(path: file.path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TABLE item (id TEXT)")
                try db.execute(sql: "INSERT INTO item VALUES ('x')")
                try db.execute(sql: "PRAGMA user_version = 99")
            }
        }
        let before = try Data(contentsOf: file)

        let result = await FlotsamDatabase.openBaseline(folder: root)

        guard case .failure(let error) = result else {
            Issue.record("a version-99 database opened")
            return
        }
        #expect(error.code == .stoDb003)
        #expect(try Data(contentsOf: file) == before)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(!names.contains("flotsam.sqlite-wal") && !names.contains("flotsam.sqlite-shm"))
    }

    /// OC-7136. Given a migration that fails part-way, when the database opens, then the open fails with STO-DB-003, the
    /// file is still at version 1 with its 3 items and without the half-built table, and the pre-migration copy exists.
    @Test func oc7136_failedMigrationRollsBackAndKeepsTheCopy() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVersionOne(root)
        let failing = Migration(version: 2) { db in
            try db.execute(sql: "CREATE TABLE probe (id INTEGER)")
            throw Boom()
        }

        let result = await FlotsamDatabase.open(
            folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.baseline + [failing])

        guard case .failure(let error) = result else {
            Issue.record("a failing migration reported success")
            return
        }
        #expect(error.code == .stoDb003)
        let live = try snapshot(root.appendingPathComponent("flotsam.sqlite"))
        #expect(live.version == 1)
        #expect(live.items == 3)
        #expect(!live.hasProbe)
        let copy = try snapshot(root.appendingPathComponent("pre-migration/flotsam-v1.sqlite"))
        #expect(copy.version == 1 && copy.items == 3)
    }
}
