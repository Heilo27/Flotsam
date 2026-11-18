import FlotsamBase
import FlotsamPayload
import Foundation
import Testing
@testable import FlotsamShelf
@testable import FlotsamStorage

// FRD-006 oracle contract tests, remaining behaviours with a FlotsamCore seam (OC-6074, OC-6096, OC-6116).
//
// Everything else in the FRD-006 oracle either already has a citing test elsewhere (OC-6032..6036, 6083..6088,
// 6090..6095, 6097..6107, 6109, 6110, 6117, 6118, 6120) or has no seam below AppKit and is marked "no seam: manual"
// in the report: OC-6007, 6010, 6011, 6037 (panel, animation and focus behaviour), OC-6077 (private gesture
// threshold in the app target), OC-6081 (NSDraggingSource callback), OC-6089 (panel hit-testing), OC-6108 (general
// pasteboard, no port in FlotsamCore), OC-6111..6114 (Finder, permissions, multi-display), OC-6121 (appearance).

private final class BehaviorSink: LogSink, @unchecked Sendable {
    func write(_ record: LogRecord) {}
}

private final class BehaviorKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// Every path exists, nothing is touched; enough to plan a drag of text cards.
private struct EverythingExists: FileSystemPort {
    func fileExists(at url: URL) -> Bool { true }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { .success(()) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { .success(()) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { .success(()) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { .success(()) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { .success([]) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { nil }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { .success(()) }
    func readFile(at url: URL) -> FlotsamResult<Data> { .success(Data()) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { .success(Data()) }
    func fileInfo(at url: URL) -> FileInfo? { nil }
    func availableCapacity(at url: URL) -> Int64? { nil }
}

private func fileList(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

@Suite struct Frd006ContractBehaviorTests {
    // OC-6074 (testable half). given 3 cards selected, when they are dragged, then the plan provides for 3 cards, which
    // is the number the drag image's badge shows; one 3-file bundle is 1 card (not 3), and 3 cards of one file each
    // are 3. Red if the count is taken from pasteboard items, or from the whole selection rather than the cards that
    // contributed. The stacked image and the badge drawing are AppKit (no seam: manual).
    @Test("OC-6074 the badge count is cards that contribute, not pasteboard items")
    func oc6074_badgeCountIsCards() throws {
        func text(_ n: Int) -> ShelfDragCandidate {
            ShelfDragCandidate(
                itemId: shelfID(n),
                content: ItemContent(kind: .text, plainText: "card \(n)", representations: [], members: []))
        }
        let three = try ShelfDragPlanner.plan([text(1), text(2), text(3)], files: EverythingExists()).get()
        #expect(three.cardCount == 3)
        #expect(three.draggedItemIds == [shelfID(1), shelfID(2), shelfID(3)])

        let bundle = ShelfDragCandidate(
            itemId: shelfID(4),
            content: ItemContent(
                kind: .bundle, plainText: nil, representations: [],
                members: ["/a", "/b", "/c"].map { ItemMember(path: $0, bookmark: nil, isDirectory: false) }))
        let one = try ShelfDragPlanner.plan([bundle], files: EverythingExists()).get()
        #expect(one.items.count == 3)
        #expect(one.cardCount == 1)

        let single = try ShelfDragPlanner.plan([text(1)], files: EverythingExists()).get()
        #expect(single.cardCount == 1)
    }

    // OC-6096 (testable half). given a file in a folder, when it is dropped onto the Shelf, then the original still exists
    // at its path with its bytes, nothing else in its folder changed, the library holds exactly one new item that
    // points at the original path, and a freshly opened database sees the same. Red if the ingest copies, moves or
    // removes the original, or stores nothing. Finder staying frontmost is AppKit (no seam: manual).
    @Test("OC-6096 dropping a file leaves the original in place and stores a reference to it")
    func oc6096_originalStaysPut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frd006-drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let filesFolder = root.appendingPathComponent("files")
        let dataFolder = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: filesFolder, withIntermediateDirectories: true)
        let original = filesFolder.appendingPathComponent("original-6096.txt")
        let neighbour = filesFolder.appendingPathComponent("neighbour.txt")
        try Data("original bytes".utf8).write(to: original)
        try Data("neighbour bytes".utf8).write(to: neighbour)
        #expect(try fileList(filesFolder) == ["neighbour.txt", "original-6096.txt"])

        let database = try await FlotsamDatabase.open(folder: dataFolder, logSink: BehaviorSink()).get()
        let before = try await database.items(matching: LibraryQuery()).get().rows.count
        #expect(before == 0)

        let drop = try ShelfDropPlanner.plan(
            types: ["public.file-url"],
            representations: [PasteboardRepresentation(uti: "public.file-url", data: Data(original.absoluteString.utf8))],
            source: nil, occurredAt: Date(timeIntervalSince1970: 1_800_000_000), isReadable: { _ in true }).get()
        let ingest = IngestActor(database: database, settings: SettingsStore(store: BehaviorKV()))
        let itemId: UUID
        switch try await ingest.ingest(drop.candidate).get().outcome {
        case .created(let id): itemId = id
        case .bumped, .unchanged: Issue.record("a first drop must create an item"); return
        }

        #expect(try fileList(filesFolder) == ["neighbour.txt", "original-6096.txt"])
        #expect(try Data(contentsOf: original) == Data("original bytes".utf8))
        #expect(try Data(contentsOf: neighbour) == Data("neighbour bytes".utf8))

        let fresh = try await FlotsamDatabase.open(folder: dataFolder, logSink: BehaviorSink()).get()
        let rows = try await fresh.items(matching: LibraryQuery()).get().rows
        #expect(rows.count == 1)
        #expect(rows.map(\.id) == [itemId])
        let members = try await fresh.content(of: itemId).get().members
        #expect(members.count == 1)
        #expect(members.first?.path.hasSuffix("/files/original-6096.txt") == true)
    }

    // OC-6116 (testable half). given more thumbnail bytes than the ceiling, when they are stored, then memory holds at
    // most 64 MB: exactly 64 x 1 MB all stay, the 65th pushes out the oldest, a recent read protects an entry, and a
    // single entry bigger than the ceiling is not kept. Red if the ceiling is raised, the comparison is off by one,
    // eviction is not least-recently-used, or an oversized entry is kept. The 10,000-image scroll is manual.
    @Test("OC-6116 the thumbnail memory cache never holds more than 64 MB, evicting least recently used first")
    func oc6116_ceiling() async {
        let megabyte = Data(count: 1_024 * 1_024)
        let cache = ThumbnailCache()
        for n in 0..<64 { await cache.store(megabyte, for: "k\(n)") }
        // Boundary: exactly at the ceiling, nothing is evicted.
        var held = 0
        for n in 0..<64 where await cache.cached("k\(n)") != nil { held += 1 }
        #expect(held == 64)

        // Max + 1: the least recently used is the one to go. The loop above read k0 first and k63 last, so k0 is oldest.
        await cache.store(megabyte, for: "k64")
        #expect(await cache.cached("k0") == nil)
        var heldAfter = 0
        for n in 1...64 where await cache.cached("k\(n)") != nil { heldAfter += 1 }
        #expect(heldAfter == 64)

        // Recency: k1 is now the oldest. Reading it makes k2 the oldest, so the next store pushes out k2 and keeps k1
        // (a first-in-first-out cache would drop k1 here).
        _ = await cache.cached("k1")
        await cache.store(megabyte, for: "k65")
        #expect(await cache.cached("k2") == nil)
        #expect(await cache.cached("k1") != nil)
        #expect(await cache.cached("k65") != nil)

        // One entry larger than the ceiling cannot stay at all.
        let big = ThumbnailCache()
        await big.store(Data(count: 64 * 1_024 * 1_024 + 1), for: "huge")
        #expect(await big.cached("huge") == nil)
    }
}
