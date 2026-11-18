import Foundation
import GRDB
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamStorage
@testable import FlotsamShelf

// FRD-007 8T contract tests, slice S3b (Shelf half): OC-7150 (a Shelf drop goes through the one dedupe ingest) and
// OC-7126 (a Shelf delete removes the item from the Shelf and the Library, with its blobs and thumbnails). Real
// ShelfDropService, IngestActor, ShelfModel and FlotsamDatabase over a scratch folder; only the presenter, key-value
// store, clock, sink, paster and host are fakes. Every count is read through a FRESH database instance on the same
// folder; files are checked on disk. The 1 s wall-clock bound and the on-screen disappearance are in
// FRD007ContractTestsGaps.swift (no seam).

@MainActor
private final class LifePresenter: ErrorPresenter {
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) {}
    func presentFatal(_ error: FlotsamError) {}
}

private final class LifeKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class LifeClock: WallClock, @unchecked Sendable {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(for duration: Duration) async {}
}

private final class LifeSink: LogSink, @unchecked Sendable {
    func write(_ record: LogRecord) {}
}

@MainActor
@Suite("FRD-007 contract: Shelf storage lifecycle", .serialized, .timeLimit(.minutes(2)))
struct FRD007ContractShelfStorageLifecycleTests {
    private struct Rig {
        let root: URL
        let dataFolder: URL
        let database: FlotsamDatabase
        let service: ShelfDropService

        static func make() async throws -> Rig {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-7126-\(UUID().uuidString)")
            let data = root.appendingPathComponent("data")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try await FlotsamDatabase.open(folder: data, logSink: LifeSink()).get()
            let reporter = ErrorReporter(presenter: LifePresenter(), clock: LifeClock(), sink: LifeSink())
            let settings = SettingsStore(store: LifeKV())
            let service = ShelfDropService(
                ingest: IngestActor(database: database, settings: settings), reporter: reporter, sink: LifeSink(),
                dropCompleted: {})
            return Rig(root: root, dataFolder: data, database: database, service: service)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        /// `rich` adds an RTF representation: plain text lives in the row alone, a rich item also has blob files.
        func dropText(_ text: String, at seconds: TimeInterval, rich: Bool = false) async -> UUID? {
            var types = [PasteboardTypes.plainText]
            var reps = [PasteboardRepresentation(uti: PasteboardTypes.plainText, data: Data(text.utf8))]
            if rich {
                types.append(PasteboardTypes.rtf)
                reps.append(PasteboardRepresentation(uti: PasteboardTypes.rtf, data: Data("{\\rtf1 \(text)}".utf8)))
            }
            let result = await service.drop(
                types: types, representations: reps, source: nil, originatesInShelf: false,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
            if case .stored(let id, _) = result { return id }
            return nil
        }

        func freshDatabase() async throws -> FlotsamDatabase {
            try await FlotsamDatabase.open(folder: dataFolder, logSink: LifeSink()).get()
        }

        /// Library rows read through a database instance the drop and delete paths never touched.
        func libraryIDs() async throws -> [UUID] {
            try await freshDatabase().items(matching: LibraryQuery()).get().rows.map(\.id)
        }

        /// (copyCount, lastCopiedAt in epoch milliseconds) of one item, read through a fresh instance.
        func counters(of id: UUID) async throws -> (copyCount: Int, lastCopiedAtMillis: Int64) {
            let fresh = try await freshDatabase()
            return try await fresh.pool.read { db in
                let row = try #require(
                    try Row.fetchOne(db, sql: "SELECT copyCount, lastCopiedAt FROM item WHERE id = ?", arguments: [id.uuidString]))
                return (copyCount: row["copyCount"], lastCopiedAtMillis: row["lastCopiedAt"])
            }
        }

        /// Names of every file below `blobs/`, relative to it.
        func blobFiles() -> [String] {
            let base = dataFolder.appendingPathComponent("blobs")
            let paths = FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String] ?? []
            return paths.filter { $0.contains("/") }.sorted()  // files only: "<shard>/<file>"
        }

        /// Blob files whose name starts with `id`.
        func blobFiles(of id: UUID) -> [String] { blobFiles().filter { $0.contains(id.uuidString) } }

        func thumbnailURLs(of id: UUID) -> [URL] {
            [256, 512].map { dataFolder.appendingPathComponent("thumbs/\(id.uuidString)-\($0).jpg") }
        }

        func writeThumbnails(of id: UUID) throws {
            try FileManager.default.createDirectory(
                at: dataFolder.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
            for url in thumbnailURLs(of: id) { try Data("jpeg".utf8).write(to: url) }
        }
    }

    // MARK: OC-7150

    /// OC-7150. The same text dropped twice is one item whose copyCount is 2 and whose lastCopiedAt is the second
    /// drop's time; a different text is a new item.
    /// Red if the Shelf drop bypasses the dedupe ingest (a second row), or bumps without counting the copy.
    @Test("OC-7150 a Shelf drop of identical text adds no item, makes copyCount 2 and moves lastCopiedAt; other text adds one")
    func oc7150_identicalDropBumpsInsteadOfAdding() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        // given text item T exists with copyCount 1, dropped at t0
        let first = try #require(await rig.dropText("MARK-DEDUPE-T", at: 0))
        #expect(try await rig.libraryIDs() == [first])
        let before = try await rig.counters(of: first)
        #expect(before.copyCount == 1)
        #expect(before.lastCopiedAtMillis == 1_800_000_000_000)

        // when the identical text is dropped on the Shelf 60 s later
        let second = try #require(await rig.dropText("MARK-DEDUPE-T", at: 60), "the identical drop stored nothing")

        // then no new item (delta 0), the same id, copyCount 2, lastCopiedAt is the second drop's time
        #expect(second == first)
        #expect(try await rig.libraryIDs() == [first])
        let after = try await rig.counters(of: first)
        #expect(after.copyCount == 2)
        #expect(after.lastCopiedAtMillis == 1_800_000_060_000)

        // negative: a different text is a new item (delta +1) and T is untouched
        let other = try #require(await rig.dropText("MARK-DEDUPE-OTHER", at: 120))
        #expect(other != first)
        #expect(Set(try await rig.libraryIDs()) == [first, other])
        let untouched = try await rig.counters(of: first)
        #expect(untouched.copyCount == 2)
    }

    // MARK: OC-7126

    /// OC-7126. Deleting V from the Shelf removes it from the Shelf and from the Library (count delta -1 in each),
    /// removes its blob files and thumbnails, and leaves the other item, its blobs and its thumbnails alone.
    /// Red if the Shelf delete leaves the row, the blobs, or the thumbnails behind, or deletes the wrong item.
    @Test("OC-7126 deleting V from the Shelf: -1 on the Shelf and in the Library, V's blobs and thumbnails gone, survivor intact")
    func oc7126_shelfDeleteRemovesRowBlobsAndThumbnails() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        // given V and a survivor S, both stored, both on the Shelf, each with blob files and thumbnails
        let victim = try #require(await rig.dropText("MARK-VICTIM", at: 0, rich: true))
        let survivor = try #require(await rig.dropText("MARK-SURVIVOR", at: 1, rich: true))
        try rig.writeThumbnails(of: victim)
        try rig.writeThumbnails(of: survivor)
        let model = ShelfModel(
            source: rig.database, paster: FakeShelfPaster(), host: FakeShelfHost(), events: rig.database.events,
            details: rig.database)
        await model.open(target: textEdit, sticky: true)
        #expect(Set(model.sections().flatMap(\.cards).map(\.id)) == [victim, survivor])
        #expect(Set(try await rig.libraryIDs()) == [victim, survivor])
        let victimBlobs = rig.blobFiles(of: victim)
        let survivorBlobs = rig.blobFiles(of: survivor)
        try #require(!victimBlobs.isEmpty, "the fixture stored no blob for V; the blob half would be vacuous")
        #expect(!survivorBlobs.isEmpty)
        #expect(rig.thumbnailURLs(of: victim).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        // when V is deleted from the Shelf (a single unpinned item needs no confirmation)
        model.perform(.delete, on: victim)
        await model.settled()

        // then the Shelf shows only S (-1), the Library holds only S (-1), V's files are gone, S's are intact
        #expect(model.sections().flatMap(\.cards).map(\.id) == [survivor])
        #expect(try await rig.libraryIDs() == [survivor])
        #expect(rig.blobFiles(of: victim).isEmpty, "V's blob files remain: \(rig.blobFiles(of: victim))")
        #expect(rig.thumbnailURLs(of: victim).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(rig.blobFiles(of: survivor) == survivorBlobs)
        #expect(rig.thumbnailURLs(of: survivor).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}
