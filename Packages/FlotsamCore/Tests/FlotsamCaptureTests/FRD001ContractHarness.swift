import CoreGraphics
import Foundation
import GRDB
import ImageIO
import FlotsamBase
import FlotsamPayload
@testable import FlotsamStorage
@testable import FlotsamCapture

// Shared harness for the FRD-001 8T contract tests (oracle .claude/oracle/frd-001-contract.json). Part 1 is
// OC-1001..1055 (FRD001ContractTests.swift); later parts reuse this file. Everything here is a fake at a system
// seam (pasteboard, source-app lookup, key-value store, presenter, log sink, clock); ClipboardCapture,
// CaptureClassifier, IngestActor and a real on-disk FlotsamDatabase are the real collaborators.
//
// API:
//   let rig = try await ContractRig.make()          // capture is started; call `await rig.finish()` at the end
//   rig.pasteboard.copy([...])                       // one or many reps, duplicates of one UTI allowed
//   await rig.process()                              // one tick, then wait until everything handed off is ingested
//   try await rig.itemCount() / rig.items() / rig.members(of:) / rig.searchCount("text")
//   rig.sink.logged(.capPol001)                      // log records carrying that code (error or skipped event)
//   await rig.until { ... }                          // poll (5 s) for fire-and-forget reporter work
//   await rig.flush()                                // let fire-and-forget reports settle before a NEGATIVE check

// MARK: Fakes

/// Pasteboard with several representations per type (one per NSPasteboardItem) and fault knobs.
@MainActor
final class ContractPasteboard: PasteboardPort {
    private(set) var changeCount = 1
    private var reps: [PasteboardRepresentation] = []
    /// Every UTI whose bytes were asked for through `readSnapshot`.
    private(set) var bytesRequested: [String] = []
    private(set) var typeQueries = 0
    private(set) var snapshotReads = 0
    /// Reading any of these UTIs fails (a data provider that throws).
    var failingTypes: Set<String> = []
    /// Every `readSnapshot` fails.
    var failAllReads = false
    /// `readSnapshot` reports `changeCount + 1` (the pasteboard changed under the read).
    var driftOnRead = false

    /// Replaces the contents (several entries may share a UTI) and bumps `changeCount`. `[]` is an empty-types copy.
    func copy(_ representations: [PasteboardRepresentation]) {
        reps = representations
        changeCount += 1
    }

    func copy(_ pairs: [(String, Data)]) { copy(pairs.map { PasteboardRepresentation(uti: $0.0, data: $0.1) }) }
    func copy(_ uti: String, _ data: Data) { copy([PasteboardRepresentation(uti: uti, data: data)]) }
    func copyText(_ text: String, extra: [(String, Data)] = []) {
        copy([(PasteboardTypes.plainText, Data(text.utf8))] + extra)
    }

    func currentTypeIdentifiers() -> [String] {
        typeQueries += 1
        var seen: [String] = []
        for rep in reps where !seen.contains(rep.uti) { seen.append(rep.uti) }
        return seen
    }

    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        snapshotReads += 1
        bytesRequested += types
        if failAllReads || !failingTypes.isDisjoint(with: types) {
            return .failure(FlotsamError(.capOs001, "fake provider failed"))
        }
        let selected = reps.filter { types.contains($0.uti) }
        return .success(PasteboardSnapshot(
            changeCount: driftOnRead ? changeCount + 1 : changeCount,
            typeIdentifiers: currentTypeIdentifiers(), representations: selected))
    }

    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        copy(representations)
        return .success(changeCount)
    }
}

@MainActor
final class ContractSourceApps: SourceAppPort {
    var frontmost: SourceApp?
    init(frontmost: SourceApp?) { self.frontmost = frontmost }
    func frontmostApp() -> SourceApp? { frontmost }
    func localizedName(forBundleId: String) -> String? { nil }
}

final class ContractKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// Records every log record the code under test writes.
final class RecordingSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { storage.append(record) } }
    var records: [LogRecord] { lock.withLock { storage } }

    /// Records for this code: an error record whose headline starts with it, or an event record carrying `code=`.
    func logged(_ code: ErrorCode) -> [LogRecord] {
        records.filter { $0.headline.hasPrefix(code.rawValue + " ") || $0.publicContext.contains("code=\(code.rawValue)") }
    }

    /// `pasteboard.processed` records that were skipped.
    var skipped: [LogRecord] {
        records.filter { $0.headline == "pasteboard.processed" && $0.publicContext.contains("outcome=skipped") }
    }

    /// Every character of every record, public and private, as one string.
    var everything: String {
        records.map { "\($0.publicText) \($0.privateText) \($0.message ?? "")" }.joined(separator: "\n")
    }
}

@MainActor
final class RecordingPresenter: ErrorPresenter {
    private(set) var huds: [String] = []
    private(set) var noticeLists: [[Notice]] = []
    private(set) var fatals: [FlotsamError] = []
    func showHUD(message: String) { huds.append(message) }
    func noticesChanged(_ notices: [Notice]) { noticeLists.append(notices) }
    func presentFatal(_ error: FlotsamError) { fatals.append(error) }
    var latestNotices: [Notice] { noticeLists.last ?? [] }
}

final class ManualClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func sleep(for duration: Duration) async {}
}

// MARK: Rig

struct StoredItem: Equatable {
    let id: String
    let kind: String
    let plainText: String?
    let copyCount: Int
    let pixelWidth: Int?
    let pixelHeight: Int?
    let sourceBundleId: String?
    let sourceName: String?
}

@MainActor
final class ContractRig {
    let folder: URL
    let files: URL
    let database: FlotsamDatabase
    let pasteboard = ContractPasteboard()
    let sourceApps: ContractSourceApps
    let ledger = OwnWriteLedger()
    let settings: SettingsStore
    let sink = RecordingSink()
    let presenter = RecordingPresenter()
    let clock = ManualClock()
    let reporter: ErrorReporter
    private(set) var capture: ClipboardCapture!
    /// Bundle identifiers on the ignored list (read live by capture on every change).
    var ignored: Set<String> {
        get { ignoredBox.value }
        set { ignoredBox.value = newValue }
    }
    private let ignoredBox = IgnoredBox()

    final class IgnoredBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Set<String> = []
        var value: Set<String> {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    static let writerApp = SourceApp(bundleId: "com.example.writer", name: "Writer")

    static func make(frontmost: SourceApp? = ContractRig.writerApp, startCapture: Bool = true) async throws -> ContractRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-frd001-\(UUID().uuidString)")
        let database = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data")).get()
        return ContractRig(root: root, database: database, frontmost: frontmost, startCapture: startCapture)
    }

    private init(root: URL, database: FlotsamDatabase, frontmost: SourceApp?, startCapture: Bool) {
        self.folder = root.appendingPathComponent("data")
        self.files = root.appendingPathComponent("files")
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        self.database = database
        self.sourceApps = ContractSourceApps(frontmost: frontmost)
        self.settings = SettingsStore(store: ContractKV())
        self.reporter = ErrorReporter(presenter: presenter, clock: clock, sink: sink)
        let box = ignoredBox
        self.capture = ClipboardCapture(
            pasteboard: pasteboard, sourceApps: sourceApps, ownWrites: ledger,
            ingest: IngestActor(database: database, settings: settings), settings: settings,
            reporter: reporter, ignoredApps: { box.value }, clock: clock, sink: sink)
        if startCapture { capture.start() }
    }

    func finish() async {
        await capture.stop()
        try? FileManager.default.removeItem(at: files.deletingLastPathComponent())
    }

    // MARK: Driving

    /// One poll, then waits until every payload handed off has been ingested (and its warnings reported), and
    /// restarts the consumer so the next copy can be processed.
    func process() async {
        capture.captureNow()
        await capture.stop()
        capture.start()
        await flush()
    }

    /// Lets fire-and-forget `reporter.report` tasks settle. Use before asserting that a log record is ABSENT; pair it
    /// with a positive `until` on the record that must be present.
    func flush() async {
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(30))
            _ = await reporter.recentErrors()
        }
    }

    /// Polls `condition` for up to `seconds`; returns whether it became true.
    @discardableResult
    func until(seconds: Double = 5, _ condition: () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return (try? await condition()) == true
    }

    /// Copy text and process it.
    func copyText(_ text: String, extra: [(String, Data)] = []) async {
        pasteboard.copyText(text, extra: extra)
        await process()
    }

    // MARK: Observing the database (persisted rows, not in-memory arrays)

    func itemCount() async throws -> Int {
        try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") ?? -1 }
    }

    /// All items in insertion order.
    func items() async throws -> [StoredItem] {
        try await database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, kind, plainText, copyCount, pixelWidth, pixelHeight, sourceBundleId, sourceName FROM item ORDER BY rowid")
                .map { StoredItem(
                    id: $0["id"], kind: $0["kind"], plainText: $0["plainText"], copyCount: $0["copyCount"],
                    pixelWidth: $0["pixelWidth"], pixelHeight: $0["pixelHeight"],
                    sourceBundleId: $0["sourceBundleId"], sourceName: $0["sourceName"]) }
        }
    }

    /// Kinds of all items in insertion order.
    func kinds() async throws -> [String] { try await items().map(\.kind) }

    func item(withText text: String) async throws -> [StoredItem] {
        try await items().filter { $0.plainText == text }
    }

    func members(of itemId: String) async throws -> [String] {
        try await database.pool.read {
            try String.fetchAll($0, sql: "SELECT path FROM bundleMember WHERE itemId = ? ORDER BY ordinal", arguments: [itemId])
        }
    }

    func memberRows(of itemId: String) async throws -> [(path: String, bookmark: Data?, isDirectory: Bool)] {
        try await database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT path, bookmark, isDirectory FROM bundleMember WHERE itemId = ? ORDER BY ordinal", arguments: [itemId])
                .map { (path: $0["path"], bookmark: $0["bookmark"], isDirectory: $0["isDirectory"]) }
        }
    }

    /// Library search: item count for `text` through the real query layer.
    func searchCount(_ text: String) async throws -> Int {
        try await database.count(filter: .all, text: text).get()
    }

    func representationTypes(of itemId: String) async throws -> [String] {
        guard let id = UUID(uuidString: itemId) else { return [] }
        return try await database.content(of: id).get().representations.map(\.uti)
    }

    /// Reads the persisted store through a second `FlotsamDatabase` on the same folder (not the capture's instance).
    func freshItemCount() async throws -> Int {
        let fresh = try await FlotsamDatabase.open(folder: folder).get()
        return try await fresh.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") ?? -1 }
    }

    // MARK: Files

    @discardableResult
    func makeFile(_ name: String, bytes: Data = Data("x".utf8), in directory: URL? = nil) throws -> URL {
        let url = (directory ?? files).appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    @discardableResult
    func makeDirectory(_ name: String) throws -> URL {
        let url = files.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Total allocated file size under the data folder.
    func dataFolderBytes() -> Int {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return -1 }
        var total = 0
        for case let url as URL in walker { total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }
}

// MARK: Pasteboard value helpers

enum PB {
    static let text = "public.utf8-plain-text"
    static let png = "public.png"
    static let jpeg = "public.jpeg"
    static let tiff = "public.tiff"
    static let html = "public.html"
    static let rtf = "public.rtf"
    static let url = "public.url"
    static let fileURL = "public.file-url"
    static let pdf = "com.adobe.pdf"

    static func data(_ text: String) -> Data { Data(text.utf8) }
    static func fileURLData(_ url: URL) -> Data { Data(url.absoluteString.utf8) }
    static func fileURLRep(_ url: URL) -> PasteboardRepresentation { PasteboardRepresentation(uti: fileURL, data: fileURLData(url)) }
    static func fileURLReps(_ urls: [URL]) -> [PasteboardRepresentation] { urls.map(fileURLRep) }
}

// MARK: Image fixtures

enum TestImage {
    enum Format: String { case png = "public.png", jpeg = "public.jpeg", tiff = "public.tiff" }

    /// A `width` x `height` image whose pixels depend on `seed`, so two images with different seeds differ.
    static func make(_ format: Format, width: Int, height: Int, seed: UInt8 = 0) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            context.setFillColor(CGColor(
                red: CGFloat((Int(seed) + y * 7) % 256) / 255, green: CGFloat((Int(seed) * 3 + 40) % 256) / 255,
                blue: CGFloat((y * 13) % 256) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, format.rawValue as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination), "fixture encode failed")
        return output as Data
    }

    /// Raw RGBA bytes of the first image in `data`, for comparing pixels across formats.
    static func pixels(_ data: Data) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (width, height, buffer) : nil
    }
}
