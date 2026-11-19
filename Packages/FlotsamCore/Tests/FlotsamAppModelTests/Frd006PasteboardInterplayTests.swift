import FlotsamBase
import FlotsamCapture
import FlotsamPaste
import FlotsamPayload
@testable import FlotsamShelf
@testable import FlotsamStorage
import Foundation
import GRDB
import Testing

/// TASK-292 / FR-006-16 / AC-001-03: a Shelf paste and a Shelf drop each leave exactly one history item, and the
/// capture poller adds no duplicate.
///
/// The decision logic is already package-side: the own-write ledger and markers (`OwnWriteLedger`, FR-001-03), the
/// paste sequence (`PasteService`) and the poller's gate (`ClipboardCapture`, CAP-POL-004), and `ShelfDropService`. The
/// only App code on the path is `ShelfPasteAdapter` (the Shelf's `ShelfPasting` port onto `PasteService`), compiled
/// here from the App source by symlink, so these tests run the real adapter, the real service, the real ledger and the
/// real poller over a real database. Fakes are the pasteboard, the frontmost app, ⌘V, the clock and the presenter.
/// What stays manual is the AppKit half: that `AppContainer` hands the Shelf the one shared ledger, and that a drop
/// reads the drag pasteboard (`ShelfPanelController.shelfPerformDrop`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct Frd006PasteboardInterplayTests {
    // MARK: Fakes

    /// The general pasteboard. `copy` is another app's write (no markers); `write` is Flotsam's (the ledger's markers
    /// are in the representations it is given).
    private final class GeneralPasteboard: PasteboardPort {
        private(set) var changeCount = 0
        private var current: [PasteboardRepresentation] = []
        private(set) var flotsamWrites = 0

        func currentTypeIdentifiers() -> [String] { current.map(\.uti) }
        func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
            .success(PasteboardSnapshot(
                changeCount: changeCount, typeIdentifiers: currentTypeIdentifiers(),
                representations: current.filter { types.contains($0.uti) }))
        }
        func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
            current = representations
            changeCount += 1
            flotsamWrites += 1
            return .success(changeCount)
        }
        func copy(_ text: String) {
            current = [PasteboardRepresentation(uti: PasteboardTypes.plainText, data: Data(text.utf8))]
            changeCount += 1
        }
    }

    private struct Editor: SourceAppPort {
        func frontmostApp() -> SourceApp? { SourceApp(bundleId: "com.example.editor", name: "Editor") }
        func localizedName(forBundleId bundleId: String) -> String? { nil }
    }

    private struct Allowed: PasteboardAccessPort { var isReadAllowed: Bool { true } }

    private final class MemoryKV: KeyValueStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func string(forKey key: String) -> String? { lock.withLock { values[key] } }
        func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
        func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
    }

    private final class NoWaitClock: WallClock, @unchecked Sendable {
        func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
        func sleep(for duration: Duration) async {}
    }

    private final class RecordingSink: LogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _records: [LogRecord] = []
        func write(_ record: LogRecord) { lock.withLock { _records.append(record) } }
        var allText: String { lock.withLock { _records.map { "\($0.publicText) \($0.privateText)" }.joined(separator: "\n") } }
    }

    @MainActor private final class Presenter: ErrorPresenter {
        func showHUD(message: String) {}
        func noticesChanged(_ notices: [Notice]) {}
        func presentFatal(_ error: FlotsamError) {}
    }

    private struct Permission: PermissionProbe {
        func isGranted(_ kind: PermissionKind) -> Bool { true }
        func request(_ kind: PermissionKind) {}
        func openSystemSettings(_ kind: PermissionKind) {}
    }

    @MainActor private struct Frontmost: FrontmostAppProvider {
        let app: FrontmostApp
        func frontmost() -> FrontmostApp? { app }
    }

    @MainActor private struct Keys: KeyEventPoster {
        func postPaste(to target: FrontmostApp) -> Bool { true }
    }

    @MainActor private final class Panel: ShelfPasteHost {
        var isPanelVisible = true
        func hidePanel() { isPanelVisible = false }
    }

    /// One stored row, as the poller or a drop left it.
    private struct Row: Equatable, FetchableRecord {
        let text: String
        let copyCount: Int
        init(text: String, copyCount: Int) { self.text = text; self.copyCount = copyCount }
        init(row: GRDB.Row) { self.init(text: row["plainText"], copyCount: row["copyCount"]) }
    }

    // MARK: Rig

    /// The real capture poller, ledger, database and paste service over one fake general pasteboard.
    @MainActor private struct Rig {
        static let target = FrontmostApp(bundleId: "com.example.editor", processId: 100)

        let pasteboard = GeneralPasteboard()
        let ledger = OwnWriteLedger()
        let database: FlotsamDatabase
        let settings = SettingsStore(store: MemoryKV())
        let sink = RecordingSink()
        let reporter: ErrorReporter
        let capture: ClipboardCapture
        let adapter: ShelfPasteAdapter
        let dropService: ShelfDropService
        let folder: URL

        init() async throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-292-\(UUID().uuidString)")
            database = try await FlotsamDatabase.open(folder: folder).get()
            let clock = NoWaitClock()
            reporter = ErrorReporter(presenter: Presenter(), clock: clock, sink: sink)
            let ingest = IngestActor(database: database, settings: settings)
            capture = ClipboardCapture(
                pasteboard: pasteboard, sourceApps: Editor(), ownWrites: ledger, ingest: ingest, settings: settings,
                reporter: reporter, ignoredApps: { [] }, access: Allowed(), clock: clock, sink: sink,
                scheduleTimer: { _, _, _ in { } })
            // The same wiring as `AppContainer.startShelf`: one `PasteService` over the shared ledger, behind the
            // adapter; a drop service over the same ingest pipeline.
            adapter = ShelfPasteAdapter(service: PasteService(
                store: database, pasteboard: pasteboard, files: LocalFileSystem(), frontmost: Frontmost(app: Self.target),
                accessibility: Permission(), keys: Keys(), clock: clock, ownWrites: ledger, sink: sink))
            dropService = ShelfDropService(ingest: ingest, reporter: reporter, sink: sink, dropCompleted: {})
            capture.start()
        }

        /// One poll; `stop` drains everything the poll handed to ingest.
        func poll() async {
            capture.captureNow()
            await capture.stop()
            capture.start()
        }

        /// Another app copies `text`; the poller sees it and stores it.
        func externalCopy(_ text: String) async throws {
            pasteboard.copy(text)
            await poll()
            for _ in 0..<200 {
                if try await rows().contains(where: { $0.text == text }) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Polls, then proves the poller has finished with everything before it: a unique external copy goes through the
        /// same single-consumer queue, so once it is stored anything earlier has been stored or skipped too.
        func settle() async throws {
            await poll()
            try await externalCopy("sentinel-\(UUID().uuidString)")
        }

        func rows() async throws -> [Row] {
            try await database.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT plainText, copyCount FROM item WHERE plainText NOT LIKE 'sentinel-%' ORDER BY plainText")
            }
        }

        func itemId(of text: String) async throws -> UUID {
            let id = try await database.pool.read { try String.fetchOne($0, sql: "SELECT id FROM item WHERE plainText = ?", arguments: [text]) }
            return try #require(id.flatMap(UUID.init(uuidString:)))
        }

        /// CAP-POL-004 skips logged so far: the observable half of "the poller recognised its own write".
        func ownWriteSkips() -> Int {
            sink.allText.components(separatedBy: ErrorCode.capPol004.rawValue).count - 1
        }

        func finish() async {
            await capture.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Paste

    // given a stored item and capture polling, when the Shelf pastes it (paste, plain text, copy), then the item count
    // and its copy count are unchanged and the poller skipped the write as its own. Red if the Shelf's paste bypasses
    // the ledger or the markers: the poller would re-ingest the pasteboard and bump the item's copy count (dedupe hides
    // the extra row, so the copy count and the skip count are the signal).
    @Test("a Shelf paste is never re-captured", arguments: [ShelfPasteMode.paste, .plainText, .copyOnly])
    func shelfPasteCreatesNoDuplicate(mode: ShelfPasteMode) async throws {
        let rig = try await Rig()
        try await rig.externalCopy("shelf-item")
        let id = try await rig.itemId(of: "shelf-item")
        #expect(try await rig.rows() == [Row(text: "shelf-item", copyCount: 1)])
        let skipsBefore = rig.ownWriteSkips()
        let writesBefore = rig.pasteboard.flotsamWrites

        let result = await rig.adapter.paste(itemId: id, mode: mode, target: Rig.target, host: Panel())
        try await rig.settle()

        // The paste really reached the pasteboard (so the poller had something to mistake for a copy)...
        #expect(rig.pasteboard.flotsamWrites == writesBefore + 1)
        #expect((try? result.get()) != nil)
        // ...and was skipped: one row, copied once, one CAP-POL-004.
        #expect(try await rig.rows() == [Row(text: "shelf-item", copyCount: 1)])
        #expect(rig.ownWriteSkips() - skipsBefore == 1)
        await rig.finish()
    }

    // Negative: the suppression is not a blanket. After a Shelf paste, another app's copy of the same text is a real
    // copy and is captured (bumps the copy count); a different text is a new item. Red if suppression swallowed
    // external writes (for example an ignore-everything-until-next-poll flag).
    @Test("after a Shelf paste an external write still captures")
    func externalWriteAfterShelfPasteStillCaptures() async throws {
        let rig = try await Rig()
        try await rig.externalCopy("shelf-item")
        let id = try await rig.itemId(of: "shelf-item")
        _ = await rig.adapter.paste(itemId: id, mode: .paste, target: Rig.target, host: Panel())
        try await rig.settle()
        #expect(try await rig.rows() == [Row(text: "shelf-item", copyCount: 1)])

        try await rig.externalCopy("another app copied this")
        try await rig.externalCopy("shelf-item")
        try await rig.settle()

        #expect(try await rig.rows() == [
            Row(text: "another app copied this", copyCount: 1),
            Row(text: "shelf-item", copyCount: 2),
        ])
        await rig.finish()
    }

    // MARK: Drop

    private static func droppedText(_ text: String) -> (types: [String], representations: [PasteboardRepresentation]) {
        ([PasteboardTypes.plainText], [PasteboardRepresentation(uti: PasteboardTypes.plainText, data: Data(text.utf8))])
    }

    // given capture polling and a drop of text onto the Shelf, when the poller runs, then there is exactly one item
    // for it, copied once, the general pasteboard was not written, and the poller skipped nothing. A drop uses the drag
    // pasteboard only (FR-006-16), so the poller has nothing to see. Red if the drop is ingested twice or leaves a
    // second ingest behind it.
    @Test("a Shelf drop produces exactly one item and the poller adds none")
    func shelfDropCreatesNoDuplicate() async throws {
        let rig = try await Rig()
        let dropped = Self.droppedText("dropped-onto-shelf")
        let changeBefore = rig.pasteboard.changeCount

        let result = await rig.dropService.drop(
            types: dropped.types, representations: dropped.representations, source: nil, originatesInShelf: false,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(rig.pasteboard.changeCount == changeBefore, "a drop never touches the general pasteboard")
        try await rig.settle()

        guard case .stored = result else { Issue.record("drop did not store: \(result)"); await rig.finish(); return }
        #expect(rig.pasteboard.flotsamWrites == 0)
        #expect(rig.ownWriteSkips() == 0)
        #expect(try await rig.rows() == [Row(text: "dropped-onto-shelf", copyCount: 1)])
        await rig.finish()
    }

    // Negative: a drop does not make the poller deaf. An external copy of the dropped text afterwards is a real copy
    // (copy count 2) and another app's different text is a new item.
    @Test("after a Shelf drop an external write still captures")
    func externalWriteAfterShelfDropStillCaptures() async throws {
        let rig = try await Rig()
        let dropped = Self.droppedText("dropped-onto-shelf")
        _ = await rig.dropService.drop(
            types: dropped.types, representations: dropped.representations, source: nil, originatesInShelf: false,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await rig.settle()

        try await rig.externalCopy("another app copied this")
        try await rig.externalCopy("dropped-onto-shelf")
        try await rig.settle()

        #expect(try await rig.rows() == [
            Row(text: "another app copied this", copyCount: 1),
            Row(text: "dropped-onto-shelf", copyCount: 2),
        ])
        await rig.finish()
    }
}
