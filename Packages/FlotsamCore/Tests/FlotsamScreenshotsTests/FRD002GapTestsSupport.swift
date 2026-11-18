import CoreGraphics
import FlotsamBase
import FlotsamPayload
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
@testable import FlotsamScreenshots
@testable import FlotsamStorage

// Shared seams for the FRD-002 gap suites (TASK-218/219/220/231/232). Unlike `WatcherRig`, which records what would be
// ingested, `RealIngestRig` wires the watcher to the real `IngestActor`, a real `FlotsamDatabase` in a temporary data
// folder and the real `DatabaseWatermarkStore`, so a test observes what the user would read back: item rows, blobs,
// thumbnails and the `meta` watermark. Folder events, time and the Notices surface stay under the test's control.
// Reuses `TempFolder`, `SteppedClock`, `FakeFolderSource`, `MutablePreferences`, `ProbedFileSystem`,
// `MemorySettingsBacking`, `WatcherLogSink`, `eventually` and `letItSettle` from the sibling support files.

/// A real, decodable PNG whose pixels are random, so two images never share a content key.
struct GapImage {
    let width: Int
    let height: Int
    let png: Data

    static func make(width: Int = 16, height: Int = 12) -> GapImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in pixels.indices where index % 4 != 3 { pixels[index] = UInt8.random(in: 0...255) }
        let space = CGColorSpaceCreateDeviceRGB()
        let image = pixels.withUnsafeMutableBytes { raw -> CGImage in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            return context.makeImage()!
        }
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination), "the test PNG must encode")
        return GapImage(width: width, height: height, png: out as Data)
    }

    /// Pixel size of encoded image bytes, read through ImageIO; nil when the bytes are not a decodable image.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }
}

/// Keeps every Notices list the reporter hands the UI, and every HUD message.
final class GapRecordingPresenter: ErrorPresenter, @unchecked Sendable {
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var lists: [[Notice]] = []
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) { lock.withLock { lists.append(notices) } }
    func presentFatal(_ error: FlotsamError) {}
    /// The Notices list as the menu bar last drew it.
    nonisolated var currentNotices: [Notice] { lock.withLock { lists.last ?? [] } }
    /// Every notice ever shown, across all list updates.
    nonisolated var everShown: [Notice] { lock.withLock { lists.flatMap { $0 } } }
}

/// The row facts a test reads back for one item.
struct GapItemRow: Equatable {
    let id: UUID
    let kind: String
    let sourceName: String?
    let sourceBundleId: String?
    let originalPath: String?
    let createdAtMillis: Int64
    let pixelWidth: Int?
    let pixelHeight: Int?
}

/// One watcher over a real database. `desktop` is the default watched folder (the system default when no preference
/// is set); every other folder is made by the test.
final class RealIngestRig: @unchecked Sendable {
    let temp: TempFolder
    let home: URL
    let desktop: URL
    /// The Flotsam data folder (database, `blobs/`, `thumbs/`, `tmp/`).
    let dataFolder: URL
    let clock: SteppedClock
    let pollTick = PollTick()
    let source = FakeFolderSource()
    let preferences = MutablePreferences()
    let fileSystem = ProbedFileSystem()
    let settings = SettingsStore(store: MemorySettingsBacking())
    /// Notices as the UI would draw them (background-origin reports only).
    let presenter = GapRecordingPresenter()
    /// Every log record the reporter, the database and the watcher write.
    let sink: WatcherLogSink
    private(set) var reporter: ErrorReporter
    private(set) var database: FlotsamDatabase
    private(set) var ingest: IngestActor
    private(set) var marks: DatabaseWatermarkStore
    private(set) var watcher: ScreenshotWatcher!

    private init(temp: TempFolder, home: URL, desktop: URL, dataFolder: URL, clock: SteppedClock, sink: WatcherLogSink, database: FlotsamDatabase) {
        self.sink = sink
        self.temp = temp
        self.home = home
        self.desktop = desktop
        self.dataFolder = dataFolder
        self.clock = clock
        self.database = database
        self.reporter = ErrorReporter(presenter: presenter, clock: clock, sink: sink)
        self.ingest = IngestActor(database: database, settings: settings)
        self.marks = DatabaseWatermarkStore(database: database)
        self.watcher = makeWatcher()
    }

    /// `watermark`: seeded into the real `meta` table before the first `start()`; nil leaves a new library.
    static func make(watermark: Date? = nil) async throws -> RealIngestRig {
        let temp = try TempFolder()
        let home = try temp.folder("home")
        let desktop = try temp.folder("home/Desktop")
        let dataFolder = temp.root.appendingPathComponent("data", isDirectory: true)
        let clock = SteppedClock()
        let sink = WatcherLogSink()
        let database = try await FlotsamDatabase.open(folder: dataFolder, clock: clock, logSink: sink).get()
        let rig = RealIngestRig(
            temp: temp, home: home, desktop: desktop, dataFolder: dataFolder, clock: clock, sink: sink, database: database)
        if let watermark { try await rig.marks.setLastScanAt(watermark).get() }
        return rig
    }

    private func makeWatcher() -> ScreenshotWatcher {
        let reporter = reporter
        return ScreenshotWatcher(
            fileSystem: fileSystem, preferences: preferences, home: home, clock: clock, eventSource: source,
            settings: settings, ingest: ingest, watermarkStore: marks,
            report: { await reporter.report($0, origin: .background) },
            clear: { await reporter.clearNotices(code: $0) },
            pollTick: pollTick, sink: sink)
    }

    /// A new launch: a FRESH database handle over the same data folder (so nothing in memory survives), a new watcher
    /// over the same watched folders and settings. Opening the second handle sweeps `data/tmp`, as a real launch does.
    func relaunch() async throws {
        database = try await FlotsamDatabase.open(folder: dataFolder, clock: clock, logSink: sink).get()
        ingest = IngestActor(database: database, settings: settings)
        marks = DatabaseWatermarkStore(database: database)
        watcher = makeWatcher()
    }

    func cleanUp() {
        if let walker = FileManager.default.enumerator(at: temp.root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        temp.cleanUp()
    }

    // MARK: Files

    /// A system-style screenshot: a real PNG with unique pixels, the screen-capture attribute, born at `born`
    /// (default: the rig clock's now).
    @discardableResult
    func shot(
        in folder: URL, _ name: String = "Screenshot \(UUID().uuidString).png", born: Date? = nil,
        image: GapImage = GapImage.make()
    ) throws -> (url: URL, image: GapImage) {
        let relative = folder.path.replacingOccurrences(of: temp.root.path + "/", with: "") + "/" + name
        let url = try temp.file(relative, bytes: image.png, screenCapture: true)
        try FileManager.default.setAttributes([.creationDate: born ?? clock.now()], ofItemAtPath: url.path)
        return (url, image)
    }

    func use(_ folder: URL) { preferences.set(location: folder.path) }
    func event(_ url: URL) { source.emit(.changed([url])) }

    // MARK: Observation (through whichever database handle is current)

    func itemCount() async throws -> Int {
        try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") ?? -1 }
    }

    func itemIds() async throws -> Set<UUID> {
        try await database.pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM item").compactMap(UUID.init(uuidString:)))
        }
    }

    /// `copyCount` per item: a re-detected known file bumps it, so a re-import hidden by dedupe still shows here.
    func copyCounts() async throws -> [UUID: Int] {
        try await database.pool.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, copyCount FROM item").compactMap { row in
                UUID(uuidString: row["id"] as String).map { ($0, row["copyCount"] as Int) }
            })
        }
    }

    func itemRow(_ id: UUID) async throws -> GapItemRow? {
        try await database.pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT kind, sourceName, sourceBundleId, originalPath, createdAt, pixelWidth, pixelHeight
                FROM item WHERE id = ?
                """, arguments: [id.uuidString]).map {
                GapItemRow(
                    id: id, kind: $0["kind"], sourceName: $0["sourceName"], sourceBundleId: $0["sourceBundleId"],
                    originalPath: $0["originalPath"], createdAtMillis: $0["createdAt"],
                    pixelWidth: $0["pixelWidth"], pixelHeight: $0["pixelHeight"])
            }
        }
    }

    /// Absolute URLs of the blob files `representation` rows name for the item (empty when none).
    func blobURLs(of id: UUID) async throws -> [URL] {
        let names = try await database.pool.read {
            try String.fetchAll($0, sql: "SELECT blobName FROM representation WHERE itemId = ? ORDER BY id", arguments: [id.uuidString])
        }
        return names.map { database.folder.blobsURL.appendingPathComponent($0) }
    }

    func representationCount(of id: UUID) async throws -> Int {
        try await database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM representation WHERE itemId = ?", arguments: [id.uuidString]) ?? -1
        }
    }

    /// The persisted `meta.screenshots.lastScanAt`, read through the current handle.
    func watermark() async throws -> Date? { try await marks.lastScanAt().get() }

    /// Waits (real time, up to 5 s) until the library holds `count` items; returns whether it did.
    func waitForItems(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if (try? await itemCount()) == count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return (try? await itemCount()) == count
    }

    // MARK: Observation of reports

    var notices: [Notice] { presenter.currentNotices }
    var noticeCodes: [ErrorCode] { presenter.currentNotices.map(\.code) }
    var logRecords: [LogRecord] { sink.records }
    func recentErrors() async -> [RaisedError] { await reporter.recentErrors() }
}
