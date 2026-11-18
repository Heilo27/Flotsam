import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
import FlotsamStorage
@testable import FlotsamShelf

// FRD-007 8T contract tests, slice S2 (Shelf half): OC-7104. Real ShelfDropService and IngestActor over a real
// database in a scratch folder, sharing ONE SettingsStore with the capture mode set; only the presenter, key-value
// store, clock and sink are fakes. Counts and identity are read through a FRESH database instance on the same folder.
// The Save Clipboard half is in FlotsamCaptureTests (same file name). The contract's single N+3 across Shelf drops
// AND Save Clipboard needs Shelf and Capture in one target (ADR-0001); see FRD007ContractTestsGaps.swift.

@MainActor
private final class ModePresenter: ErrorPresenter {
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) {}
    func presentFatal(_ error: FlotsamError) {}
}

private final class ModeKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class ModeClock: WallClock, @unchecked Sendable {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(for duration: Duration) async {}
}

private final class ModeSink: LogSink, @unchecked Sendable {
    func write(_ record: LogRecord) {}
}

@MainActor
@Suite("FRD-007 contract: capture modes (Shelf)", .serialized, .timeLimit(.minutes(2)))
struct FRD007ContractCaptureModeShelfTests {
    private struct Rig {
        let root: URL
        let files: URL
        let settings: SettingsStore
        let service: ShelfDropService

        static func make() async throws -> Rig {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-7104-\(UUID().uuidString)")
            let files = root.appendingPathComponent("files")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            let database = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data"), logSink: ModeSink()).get()
            let reporter = ErrorReporter(presenter: ModePresenter(), clock: ModeClock(), sink: ModeSink())
            let settings = SettingsStore(store: ModeKV())
            let service = ShelfDropService(
                ingest: IngestActor(database: database, settings: settings), reporter: reporter, sink: ModeSink(),
                dropCompleted: {})
            return Rig(root: root, files: files, settings: settings, service: service)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        func dropText(_ text: String, at seconds: TimeInterval) async -> UUID? {
            let rep = PasteboardRepresentation(uti: PasteboardTypes.plainText, data: Data(text.utf8))
            let result = await service.drop(
                types: [PasteboardTypes.plainText], representations: [rep], source: nil, originatesInShelf: false,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
            if case .stored(let id, _) = result { return id }
            return nil
        }

        func dropFile(named name: String, at seconds: TimeInterval) async throws -> UUID? {
            let url = files.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            let rep = PasteboardRepresentation(uti: PasteboardTypes.fileURL, data: Data(url.absoluteString.utf8))
            let result = await service.drop(
                types: [PasteboardTypes.fileURL], representations: [rep], source: nil, originatesInShelf: false,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
            if case .stored(let id, _) = result { return id }
            return nil
        }

        /// (id, kind, primary line) of every stored item, read through a database instance the drop path never touched.
        func stored() async throws -> [(id: UUID, kind: String, text: String?)] {
            let fresh = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data"), logSink: ModeSink()).get()
            let rows = try await fresh.items(matching: LibraryQuery()).get().rows
            return rows.map { (id: $0.id, kind: $0.kind.rawValue, text: $0.primaryLine) }
        }
    }

    /// OC-7104 (Shelf half). A text dropped while Paused and a file dropped while Curated each add exactly one item;
    /// the earlier item survives; the mode is not changed by either drop.
    /// Red if a Shelf drop honours Paused or Curated and stores nothing, or replaces an existing item.
    @Test("OC-7104 Shelf drops save in Paused (text) and Curated (file): N+2 with both new ids and the seed intact")
    func oc7104_shelfDropsSaveInEveryMode() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        // given N = 1 seeded item (dropped while Active)
        let seedID = try #require(await rig.dropText("MARK-SEED", at: 0))
        #expect(try await rig.stored().count == 1)

        // when text is dropped while Paused, then a file while Curated
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        let textID = try #require(await rig.dropText("MARK-SHELF-TEXT", at: 1), "Paused Shelf text drop stored nothing")
        rig.settings.set(CaptureMode.curated, for: SettingKeys.captureMode)
        let fileID = try #require(await rig.dropFile(named: "mark-curated.txt", at: 2), "Curated Shelf file drop stored nothing")

        // then N+2, three distinct ids, the dropped text and a file-kind row are present, the seed survives
        let rows = try await rig.stored()
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)) == [seedID, textID, fileID])
        #expect(rows.first { $0.id == seedID }?.text == "MARK-SEED")
        #expect(rows.first { $0.id == textID }?.text == "MARK-SHELF-TEXT")
        #expect(rows.first { $0.id == fileID }?.kind == "file")
        #expect(rig.settings.value(SettingKeys.captureMode) == .curated, "a drop does not change the mode")
    }
}
