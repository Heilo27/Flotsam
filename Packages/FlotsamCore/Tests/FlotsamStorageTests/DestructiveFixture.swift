import Foundation
import GRDB
import FlotsamBase
@testable import FlotsamStorage

// Shared arrangement for the FRD-007 8T destructive-path suites. Every test builds its own temp-dir store (no shared
// state). Expected values in tests are literals; this file only arranges rows and files and reads them back through a
// separate connection, so what is asserted is what a second reader of the database and the disk would see.

let mib: Int64 = 1_048_576
let hourMs: Int64 = 3_600_000
let dayMs: Int64 = 86_400_000

/// A clock the test moves by hand. Reconcile compares file modification times, so it starts at the real current time.
final class ManualClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)) {
        current = start
    }

    func now() -> Date { lock.withLock { current } }
    func sleep(for duration: Duration) async {}
    func advance(ms: Int64) { lock.withLock { current = current.addingTimeInterval(Double(ms) / 1000) } }
    var millis: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }
}

/// A file system that behaves like the local one except where a test makes it fail. Failures are matched on the path.
struct FaultyFileSystem: FileSystemPort {
    var failRemove: @Sendable (URL) -> Bool = { _ in false }
    var failList: @Sendable (URL) -> Bool = { _ in false }
    /// The file is listed and exists, but inspecting it (size, modification time) reports nothing.
    var failInfo: @Sendable (URL) -> Bool = { _ in false }
    /// Writing a file to this path fails (a blob staged under tmp/, for instance).
    var failWrite: @Sendable (URL) -> Bool = { _ in false }
    private let real = LocalFileSystem()

    init(
        failRemove: @escaping @Sendable (URL) -> Bool = { _ in false },
        failList: @escaping @Sendable (URL) -> Bool = { _ in false },
        failInfo: @escaping @Sendable (URL) -> Bool = { _ in false },
        failWrite: @escaping @Sendable (URL) -> Bool = { _ in false }
    ) {
        self.failWrite = failWrite
        self.failRemove = failRemove
        self.failList = failList
        self.failInfo = failInfo
    }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) -> FlotsamResult<Void> {
        failRemove(url) ? .failure(FlotsamError(.stoIo003, "injected remove failure")) : real.removeItem(at: url)
    }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> {
        failList(url) ? .failure(FlotsamError(.stoIo003, "injected list failure")) : real.contentsOfDirectory(at: url)
    }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> {
        failWrite(url) ? .failure(FlotsamError(.stoIo001, "injected write failure")) : real.writeFile(data, to: url, permissions: permissions)
    }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { real.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { failInfo(url) ? nil : real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { real.availableCapacity(at: url) }
}

struct Spec {
    var n: Int
    var kind: ItemKind = .text
    var ageMs: Int64 = 0
    /// When the item was first created; defaults to `ageMs` (the last copy).
    var createdAgeMs: Int64?
    var pinned = false
    var trigger: String?
    var hotkey: Int?
    var releasedAgoMs: Int64?
    var blobs = 0
    var repBytes: Int64 = 0
    var text: String?
    var originalPath: String?
    var members: [(path: String, isDirectory: Bool)] = []
    var thumbs = false
}

/// Keeps every log record a database writes, whole, so a test sees what a release build redacts as well as what it
/// shows. `os.Logger` cannot do that: FR-000-10 makes the item id, the static message and the cause `.private`, and
/// the unified log reads them back as `<private>`. One sink per store, so parallel suites cannot see each other's
/// lines and a count of lines is exact, not a lower bound.
final class RecordingLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LogRecord] = []

    func write(_ record: LogRecord) { lock.withLock { recorded.append(record) } }

    var records: [LogRecord] { lock.withLock { recorded } }

    /// Each record as one line: the public text, then the private text (what a developer with the debugger attached
    /// would see). Lines that contain every fragment.
    func lines(containing fragments: [String] = []) -> [String] {
        records.map { "\($0.publicText) \($0.privateText)" }.filter { line in fragments.allSatisfy { line.contains($0) } }
    }

    /// Only what a release build writes in the clear.
    func publicLines() -> [String] { records.map(\.publicText) }
}

struct Store {
    let root: URL
    let clock: ManualClock
    let database: FlotsamDatabase
    /// Every record the database logged (see `RecordingLogSink`).
    var logs = RecordingLogSink()

    /// `migrations` defaults to the shipped schema. The migration-machinery suites pass `Migrations.baseline` so a
    /// synthetic "next release" can be layered on a version-1 file whatever the shipped latest version is.
    static func make(
        fileSystem: any FileSystemPort = LocalFileSystem(), root: URL? = nil, clock: ManualClock = ManualClock(),
        migrations: [Migration] = Migrations.all
    ) async throws -> Store {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-\(UUID().uuidString)")
        let logs = RecordingLogSink()
        let database = try await FlotsamDatabase.open(
            folder: root, fileSystem: fileSystem, clock: clock, logSink: logs, migrations: migrations).get()
        return Store(root: root, clock: clock, database: database, logs: logs)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    var blobsDir: URL { root.appendingPathComponent("blobs") }
    var thumbsDir: URL { root.appendingPathComponent("thumbs") }
    func blobURL(_ n: Int, _ ordinal: Int) -> URL {
        let id = Store.id(n).uuidString
        return blobsDir.appendingPathComponent(String(id.prefix(2))).appendingPathComponent("\(id).\(ordinal)")
    }
    func thumbURL(_ n: Int, _ edge: Int) -> URL { thumbsDir.appendingPathComponent("\(Store.id(n).uuidString)-\(edge).jpg") }
    func blobBytes(_ n: Int, _ ordinal: Int) -> Data { Data("blob-\(n)-\(ordinal)".utf8) }

    // MARK: Arrange

    func insert(_ specs: [Spec]) async throws {
        let now = clock.millis
        try await database.pool.write { db in
            for s in specs {
                let id = Store.id(s.n).uuidString
                let text = s.text ?? (s.kind == .text ? "item \(s.n)" : nil)
                try db.execute(
                    sql: """
                        INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize,
                                          pinned, updatedAt, hotkeyCode, hotkeyModifiers, "trigger", exemptReleasedAt, originalPath)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        id, s.kind.rawValue, now - (s.createdAgeMs ?? s.ageMs), now - s.ageMs, "key-\(s.n)", text, text ?? "",
                        s.repBytes * Int64(s.blobs), s.pinned ? 1 : 0, now - s.ageMs,
                        s.hotkey, s.hotkey == nil ? nil : 1, s.trigger, s.releasedAgoMs.map { now - $0 }, s.originalPath,
                    ])
                for ordinal in 1...max(s.blobs, 1) where s.blobs > 0 {
                    let name = "\(id.prefix(2))/\(id).\(ordinal)"
                    try db.execute(
                        sql: "INSERT INTO representation (itemId, uti, byteSize, blobName) VALUES (?, ?, ?, ?)",
                        arguments: [id, s.kind == .image || s.kind == .screenshot ? "public.png" : "public.rtf", s.repBytes, name])
                    let url = blobURL(s.n, ordinal)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try blobBytes(s.n, ordinal).write(to: url)
                }
                if s.thumbs {
                    for edge in [256, 512] { try Data("thumb-\(s.n)-\(edge)".utf8).write(to: thumbURL(s.n, edge)) }
                }
                for (ordinal, member) in s.members.enumerated() {
                    try db.execute(
                        sql: "INSERT INTO bundleMember (itemId, ordinal, path, bookmark, isDirectory) VALUES (?, ?, ?, NULL, ?)",
                        arguments: [id, ordinal, member.path, member.isDirectory ? 1 : 0])
                }
            }
        }
    }

    func insert(_ spec: Spec) async throws { try await insert([spec]) }

    func addTags(_ names: [String], onItem n: Int) async throws {
        try await database.pool.write { db in
            for name in names {
                try db.execute(sql: "INSERT INTO tag (name, color, createdAt) VALUES (?, 'red', 0)", arguments: [name])
                try db.execute(
                    sql: "INSERT INTO itemTag (itemId, tagId) VALUES (?, last_insert_rowid())", arguments: [Store.id(n).uuidString])
            }
        }
    }

    // MARK: Read back through a separate connection

    func reader() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: root.appendingPathComponent("flotsam.sqlite").path, configuration: configuration)
    }

    /// The fixture numbers (`Store.id(n)`) of the rows present. Rows a test inserted with a random UUID
    /// are not fixture rows and are skipped, so they cannot trap the parse or collide with a number.
    func presentIds() throws -> Set<Int> {
        let ids = try reader().read { try String.fetchAll($0, sql: "SELECT id FROM item") }
        let fixtureNumbers = ids.compactMap { id -> Int? in
            guard let n = Int(id.suffix(12)), Store.id(n).uuidString == id else { return nil }
            return n
        }
        return Set(fixtureNumbers)
    }

    func count(_ table: String) throws -> Int {
        try reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
    }

    func exemptReleasedAt(_ n: Int) throws -> Int64? {
        try reader().read { try Int64?.fetchOne($0, sql: "SELECT exemptReleasedAt FROM item WHERE id = ?", arguments: [Store.id(n).uuidString]) ?? nil }
    }

    func representationCount(_ n: Int) throws -> Int {
        try reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM representation WHERE itemId = ?", arguments: [Store.id(n).uuidString])! }
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A real file outside the data folder, standing in for a file an item holds by reference.
    func makeReferencedFile(_ name: String, in directory: URL, contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func setModified(_ url: URL, agoMs: Int64) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: clock.now().addingTimeInterval(-Double(agoMs) / 1000)], ofItemAtPath: url.path)
    }
}

extension Store {
    func sumRepresentationBytes() throws -> Int64 {
        try reader().read { try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM representation")! }
    }

    func trigger(of n: Int) throws -> String? {
        try reader().read { try String?.fetchOne($0, sql: "SELECT \"trigger\" FROM item WHERE id = ?", arguments: [Store.id(n).uuidString]) ?? nil }
    }

    /// Writes a file `blobs/<shard>/<uuid>.<ordinal>` with no representation row and the given modification age.
    @discardableResult
    func plantOrphanBlob(_ n: Int, ordinal: Int = 1, ageMs: Int64) throws -> URL {
        let url = blobURL(n, ordinal)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("orphan-\(n)".utf8).write(to: url)
        try setModified(url, agoMs: ageMs)
        return url
    }

    @discardableResult
    func plant(_ relativePath: String, contents: String = "foreign", ageMs: Int64 = 0) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if ageMs > 0 { try setModified(url, agoMs: ageMs) }
        return url
    }

    func contents(_ url: URL) -> String? { (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } }
    func names(in directory: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []))
    }
}

/// Collects what `ItemEventBus` published, so a test can see what a hotkey registry or trigger snapshot would have seen.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[UUID]] = []
    private var published: [ItemEvent] = []
    private var unsubscribe: (@Sendable () -> Void)?

    init(_ bus: ItemEventBus) {
        unsubscribe = bus.subscribe { [self] event in
            lock.withLock {
                published.append(event)
                if case .itemsDeleted(let ids) = event { batches.append(ids) }
            }
        }
    }

    /// Every event, in publish order.
    var events: [ItemEvent] { lock.withLock { published } }

    var deletedBatches: [[UUID]] { lock.withLock { batches } }
    var deletedIds: Set<UUID> { Set(deletedBatches.flatMap { $0 }) }
}

/// A temp directory outside the data folder holding files an item references.
struct References {
    let directory: URL
    init() { directory = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-refs-\(UUID().uuidString)") }
    func make(_ name: String, _ contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
    func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

extension Migrations {
    /// The schema as first released (`user_version` 1). The migration-machinery suites model "a later release" as a
    /// synthetic version 2 on top of this, so they test the machinery and not whatever the shipped latest version is.
    static let baseline: [Migration] = [all[0]]
}

extension FlotsamDatabase {
    /// `open` on `Migrations.baseline` with the public entry point's defaults, for the machinery suites.
    static func openBaseline(
        folder: URL, fileSystem: any FileSystemPort = LocalFileSystem(), clock: any WallClock = SystemClock(),
        logSink: any LogSink = OSLogSink()
    ) async -> FlotsamResult<FlotsamDatabase> {
        await open(folder: folder, fileSystem: fileSystem, clock: clock, logSink: logSink, migrations: Migrations.baseline)
    }
}
