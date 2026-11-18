import CoreGraphics
import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import ImageIO
@testable import FlotsamLibrary

// Shared arrangement for the FRD-003 8T contract suites (OC-3001 and up). Everything here is test code: a key-value
// store that outlives a "relaunch", a real FlotsamDatabase in a temp folder, and a PNG generator. No product file
// is touched, and nothing here asserts.

final class ContractMemoryKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

enum ContractPNG {
    /// A solid opaque PNG of exactly `width` x `height` pixels.
    static func make(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination), "test png encode failed")
        return output as Data
    }
}

/// A LibraryViewModel over a real FlotsamDatabase in its own temp folder, so search, kinds and counts come from the
/// shipping query layer. Each test builds and cleans up its own.
@MainActor
struct RealLibrary {
    let root: URL
    // One clock for every add: secondsAgo offsets from this fixed instant, so ordering never depends on how long
    // the adds take under load (OC-3007 swapped two rows 1 s apart when the run was slow).
    let epoch = Date()
    let database: FlotsamDatabase
    let ingest: IngestActor
    let paster = FakePaster()
    let host = FakeHost()
    let prefs = FakePreferences()
    let model: LibraryViewModel
    let reported = Harness.Reported()

    static func make() async throws -> RealLibrary {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-lib-\(UUID().uuidString)")
        let database = try await FlotsamDatabase.open(folder: root).get()
        let ingest = IngestActor(database: database, settings: SettingsStore(store: ContractMemoryKV()))
        return RealLibrary(root: root, database: database, ingest: ingest)
    }

    private init(root: URL, database: FlotsamDatabase, ingest: IngestActor) {
        self.root = root
        self.database = database
        self.ingest = ingest
        let reported = reported
        // The organizer is the shipping one over the same database, so delete, tag and note go through real storage.
        let organizer = LibraryOrganizer(
            store: database,
            classifiers: ItemClassifiers(
                editedText: { ItemClassification(kind: .text, contentKey: "edit:" + $0) },
                fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) }),
            report: { reported.errors.append($0) })
        model = LibraryViewModel(
            source: database, paster: paster, host: host, preferences: prefs,
            effects: LibraryEffects(
                report: { reported.errors.append($0) }, reveal: { reported.revealed.append($0) },
                openSettings: { reported.settingsOpened += 1 },
                external: { reported.external.append(($0, $1)) }, isAccessibilityTrusted: { true }),
            organizer: organizer)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// `secondsAgo` orders items: a larger value is older.
    @discardableResult
    func add(
        _ kind: ItemKind, key: String, text: String? = nil, source: String? = nil, secondsAgo: Double = 0,
        members: [IngestMember] = [], representations: [PasteboardRepresentation] = [], originalPath: String? = nil
    ) async throws -> IngestResult {
        let candidate = IngestCandidate(
            kind: kind, contentKey: key, plainText: text, representations: representations, members: members,
            source: source.map { SourceApp(bundleId: "com.example.\($0.lowercased())", name: $0) }, origin: .pasteboard,
            occurredAt: epoch.addingTimeInterval(-secondsAgo), originalPath: originalPath)
        return try await ingest.ingest(candidate).get()
    }

    func allRows() async throws -> [ItemRow] {
        var rows: [ItemRow] = []
        var page = 0
        while true {
            let result = try await database.items(matching: LibraryQuery(page: page)).get()
            rows += result.rows
            guard result.hasMore, page < 1_000 else { break }
            page += 1
        }
        return rows
    }
}

func fullRow(
    _ n: Int, kind: ItemKind = .text, primary: String = "row", source: String? = "Safari", tags: [String] = [],
    pinned: Bool = false, trigger: Bool = false, copiedAt: Date = Date(timeIntervalSince1970: 1_000_000)
) -> ItemRow {
    ItemRow(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)) ?? UUID(), kind: kind,
        lastCopiedAt: copiedAt, pasteCount: 0, primaryLine: primary, sourceName: source, tagNames: tags,
        isPinned: pinned, hasTrigger: trigger, hasShortcut: false, pixelWidth: nil, pixelHeight: nil, memberCount: 0,
        byteSize: 0)
}

extension IngestResult {
    /// The id of the item the ingest created or touched.
    var itemId: UUID {
        switch outcome {
        case .created(let id), .bumped(let id), .unchanged(let id): id
        }
    }
}
