import CoreGraphics
import Foundation
import GRDB
import ImageIO
import FlotsamBase
@testable import FlotsamStorage

// Shared arrangement for the FRD-007 8T ingest, image-policy, disk-guard, schema, thumbnail and retention-preview
// suites. Expected values in tests are literals. This file only builds inputs (candidates, images, capacities) and
// reads results back the way a second reader would: a separate read-only connection and the files on disk.

/// A key-value store held in memory, so a test sets the image-quality preset without touching UserDefaults.
final class MemoryKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// The local file system, except that free space is whatever the test says (nil = unknown).
final class CapacityFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var capacity: Int64?

    init(capacity: Int64?) { self.capacity = capacity }
    func setCapacity(_ value: Int64?) { lock.withLock { capacity = value } }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { real.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { real.writeFile(data, to: url, permissions: permissions) }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { real.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { lock.withLock { capacity } }
}

/// The local file system, except that the first move into thumbs/ parks until the test opens the gate. While it is
/// parked, the staged thumbnail sits in tmp/, which is exactly what an unawaited ingest warm-up looks like to a test
/// that looks at tmp/ too early (TASK-404). A wait of its own caps the park so a broken test cannot hang.
final class ThumbnailGateFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var armed = false
    private var parkedNow = false

    func arm() { lock.withLock { armed = true } }
    var isParked: Bool { lock.withLock { parkedNow } }
    func open() { gate.signal() }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> {
        let park = lock.withLock { () -> Bool in
            guard armed, destination.path.contains("/thumbs/") else { return false }
            armed = false
            parkedNow = true
            return true
        }
        if park {
            _ = gate.wait(timeout: .now() + 15)
            lock.withLock { parkedNow = false }
        }
        return real.moveItem(at: source, to: destination)
    }
    func removeItem(at url: URL) -> FlotsamResult<Void> { real.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { real.writeFile(data, to: url, permissions: permissions) }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { real.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { nil }
}

// MARK: Images

enum TestImageFormat {
    case png, jpeg, tiff
    var uti: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .tiff: "public.tiff"
        }
    }
}

enum TestImage {
    /// A deterministic picture: a blue field with a red block and a green block, so a re-encode that loses or swaps
    /// pixels is visible. `transparent` clears the left half to alpha 0; `opaqueWithAlphaChannel` keeps an alpha
    /// channel that is 255 everywhere (what a macOS screenshot looks like).
    static func make(
        width: Int, height: Int, format: TestImageFormat, transparent: Bool = false, opaqueWithAlphaChannel: Bool = false
    ) -> Data {
        let hasAlpha = transparent || opaqueWithAlphaChannel
        let info = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: width / 8, y: height / 8, width: width / 4, height: height / 4))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: width * 5 / 8, y: height * 5 / 8, width: width / 4, height: height / 4))
        if transparent {
            context.clear(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
        return encode(context.makeImage()!, as: format)
    }

    static func encode(_ image: CGImage, as format: TestImageFormat) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, format.uti as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination), "test image encode failed")
        return output as Data
    }

    struct Info: Equatable {
        let type: String
        let width: Int
        let height: Int
    }

    /// The container type and pixel size of encoded bytes, or nil when they are not an image.
    static func inspect(_ data: Data) -> Info? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return Info(type: type, width: width, height: height)
    }

    /// RGBA bytes, premultiplied, row-major. Used to compare pixels across a lossless re-encode.
    static func rgba(_ data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// True when at least one pixel of the decoded bytes is not fully opaque.
    static func hasTransparentPixel(_ data: Data) -> Bool {
        guard let pixels = rgba(data) else { return false }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] != 255 }
    }
}

// MARK: Rig

/// One temp-dir store with an ingest actor over it. Each test builds its own, so nothing is shared.
struct Rig {
    let store: Store
    let settings: SettingsStore
    let ingest: IngestActor
    let fileSystem: CapacityFileSystem

    /// `capacity` defaults to 10 GiB so the disk guard stays out of the way unless a test is about it.
    static func make(quality: ImageQuality = .balanced, capacity: Int64? = 10 * 1024 * mib) async throws -> Rig {
        let fileSystem = CapacityFileSystem(capacity: capacity)
        let store = try await Store.make(fileSystem: fileSystem)
        let settings = SettingsStore(store: MemoryKV())
        settings.set(quality, for: SettingKeys.storageImageQuality)
        return Rig(store: store, settings: settings, ingest: IngestActor(database: store.database, settings: settings), fileSystem: fileSystem)
    }

    /// A rig over a caller-supplied file system (a fault or a gate). The disk guard sees unknown capacity.
    static func make(on fileSystem: any FileSystemPort) async throws -> Rig {
        let store = try await Store.make(fileSystem: fileSystem)
        let settings = SettingsStore(store: MemoryKV())
        return Rig(
            store: store, settings: settings, ingest: IngestActor(database: store.database, settings: settings),
            fileSystem: CapacityFileSystem(capacity: nil))
    }

    func cleanUp() { store.cleanUp() }

    // MARK: Building candidates

    func text(_ key: String, _ text: String, origin: CaptureOrigin = .pasteboard, at: Int64? = nil) -> IngestCandidate {
        IngestCandidate(
            kind: .text, contentKey: key, plainText: text, origin: origin,
            occurredAt: Date(timeIntervalSince1970: Double(at ?? store.clock.millis) / 1000))
    }

    func rich(_ key: String, plain: String, rtf: Data) -> IngestCandidate {
        IngestCandidate(
            kind: .richText, contentKey: key, plainText: plain,
            representations: [PasteboardRepresentation(uti: "public.rtf", data: rtf)],
            origin: .pasteboard, occurredAt: Date(timeIntervalSince1970: Double(store.clock.millis) / 1000))
    }

    func image(
        _ key: String, _ data: Data, uti: String = "public.png", kind: ItemKind = .image, origin: CaptureOrigin = .pasteboard,
        at: Int64? = nil
    ) -> IngestCandidate {
        IngestCandidate(
            kind: kind, contentKey: key, representations: [PasteboardRepresentation(uti: uti, data: data)], origin: origin,
            occurredAt: Date(timeIntervalSince1970: Double(at ?? store.clock.millis) / 1000))
    }

    func files(_ key: String, count: Int) -> IngestCandidate {
        IngestCandidate(
            kind: .bundle, contentKey: key,
            members: (0..<count).map { IngestMember(path: "/tmp/flotsam-8t/file-\($0).txt", bookmark: nil, isDirectory: false) },
            origin: .pasteboard, occurredAt: Date(timeIntervalSince1970: Double(store.clock.millis) / 1000))
    }

    // MARK: Running

    /// Ingests and returns the created id; throws on failure or on a bump so a test that expects a new item cannot
    /// pass on the wrong outcome.
    func create(_ candidate: IngestCandidate) async throws -> UUID {
        let result = try await ingest.ingest(candidate).get()
        guard case .created(let id) = result.outcome else { throw RigError.expectedCreated }
        return id
    }

    enum RigError: Error { case expectedCreated, missingRow }

    /// Waits for the unawaited ingest warm-up of image `id` to finish: both thumbnails are on disk, which is also the
    /// moment their staging files have left tmp/. Ingest returns before this (FR-007-07), so a test that looks at tmp/
    /// or thumbs/ after storing an image must wait first (TASK-404).
    func awaitThumbnails(_ id: UUID) async -> Bool {
        let urls = ThumbnailSize.allCases.map { store.thumbsDir.appendingPathComponent("\(id.uuidString)-\($0.rawValue).jpg") }
        // The warm-up is a `.utility` detached task by design (IngestActor.warmThumbnails), so under full-suite CPU load it
        // can wait several seconds for a core. The wait is on the event; 60 s is only a hang guard so a warm-up that truly
        // never runs fails instead of hanging (TASK-447, TASK-451).
        return await waitUntil(seconds: 60) { urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }
    }

    // MARK: Reading back through a separate connection

    func itemCount() throws -> Int { try store.count("item") }

    struct ItemRow {
        let kind: String
        let createdAt: Int64
        let lastCopiedAt: Int64
        let copyCount: Int
        let pasteCount: Int
        let lastUsedAt: Int64?
        let pinned: Int
        let note: String?
        let plainText: String?
        let byteSize: Int64
        let pixelWidth: Int?
        let pixelHeight: Int?
    }

    func row(_ id: UUID) throws -> ItemRow {
        try store.reader().read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT * FROM item WHERE id = ?", arguments: [id.uuidString]) else {
                throw RigError.missingRow
            }
            return ItemRow(
                kind: r["kind"], createdAt: r["createdAt"], lastCopiedAt: r["lastCopiedAt"], copyCount: r["copyCount"],
                pasteCount: r["pasteCount"], lastUsedAt: r["lastUsedAt"], pinned: r["pinned"], note: r["note"],
                plainText: r["plainText"], byteSize: r["byteSize"], pixelWidth: r["pixelWidth"], pixelHeight: r["pixelHeight"])
        }
    }

    struct RepRow: Equatable {
        let uti: String
        let byteSize: Int64
        let blobName: String
    }

    func reps(_ id: UUID) throws -> [RepRow] {
        try store.reader().read { db in
            try Row.fetchAll(
                db, sql: "SELECT uti, byteSize, blobName FROM representation WHERE itemId = ? ORDER BY id",
                arguments: [id.uuidString]
            ).map { RepRow(uti: $0["uti"], byteSize: $0["byteSize"], blobName: $0["blobName"]) }
        }
    }

    func blobData(_ rep: RepRow) -> Data? { try? Data(contentsOf: store.blobsDir.appendingPathComponent(rep.blobName)) }

    /// Every regular file under `blobs/`, as paths relative to it.
    func blobFiles() -> Set<String> {
        guard let walker = FileManager.default.enumerator(at: store.blobsDir, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        var names: Set<String> = []
        // Resolve symlinks on both sides: the temp dir is /var/... but the enumerator reports /private/var/...
        let base = store.blobsDir.resolvingSymlinksInPath().path
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            names.insert(String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)))
        }
        return names
    }

    func memberCount(_ id: UUID) throws -> Int {
        try store.reader().read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bundleMember WHERE itemId = ?", arguments: [id.uuidString])! }
    }
}

/// Polls until `condition` holds or `seconds` pass. For work that runs unawaited by design (warm thumbnails).
func waitUntil(seconds: Double = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
