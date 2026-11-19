import Foundation
import GRDB
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamStorage
@testable import FlotsamCapture

// FRD-000 FR-000-11 callsite checklist, OC-0037: the pasteboard-change-processed line, observed at the log sink the
// capture pipeline writes to, through the real ClipboardCapture + IngestWorker + IngestActor + FlotsamDatabase on a
// scratch folder. Only the pasteboard, source app, key-value store, presenter and sink are fakes. Expected values are
// literals.

private final class Board37: PasteboardPort {
    private(set) var changeCount = 1
    private var contents: [String: Data] = [:]
    func copy(_ new: [String: Data]) { contents = new; changeCount += 1 }
    func currentTypeIdentifiers() -> [String] { contents.keys.sorted() }
    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        let reps = types.compactMap { uti in contents[uti].map { PasteboardRepresentation(uti: uti, data: $0) } }
        return .success(PasteboardSnapshot(changeCount: changeCount, typeIdentifiers: currentTypeIdentifiers(), representations: reps))
    }
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> { copy([:]); return .success(changeCount) }
}

@MainActor
private struct App37: SourceAppPort {
    func frontmostApp() -> SourceApp? { SourceApp(bundleId: "com.example.writer", name: "Writer") }
    func localizedName(forBundleId: String) -> String? { nil }
}

private final class KV37: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class Presenter37: ErrorPresenter, @unchecked Sendable {
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) {}
    func presentFatal(_ error: FlotsamError) {}
}

private final class Sink37: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { records.append(record) } }
    var all: [LogRecord] { lock.withLock { records } }
    /// The pasteboard-processed lines, in write order.
    var processed: [LogRecord] { all.filter { $0.headline == "pasteboard.processed" } }
}

@MainActor
@Suite("FR-000-11 pasteboard callsite")
struct Frd000PasteboardCallsiteTests {
    private static let text = "public.utf8-plain-text"
    private static let concealed = "org.nspasteboard.ConcealedType"
    private static let transient = "org.nspasteboard.TransientType"

    /// Waits (bounded) until the sink holds `count` pasteboard-processed lines; the ingest runs off the main actor.
    private func waitForProcessed(_ sink: Sink37, _ count: Int) async {
        for _ in 0..<400 where sink.processed.count < count { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// OC-0037. Mutation: drop the `.pasteboardProcessed` log in IngestWorker (stored/deduped) or ClipboardCapture.skip
    /// (skipped), or swap the stored/deduped outcome mapping; the line count or an outcome literal goes red.
    @Test("OC-0037 a new copy, the same copy again and a transient copy log stored, deduped and skipped + CAP-POL-001, no content")
    func newDuplicateAndTransientCopies() async throws {
        // given a capture pipeline over a real database
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-oc0037-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try await FlotsamDatabase.open(folder: folder).get()
        let settings = SettingsStore(store: KV37())
        let board = Board37()
        let sink = Sink37()
        let capture = ClipboardCapture(
            pasteboard: board, sourceApps: App37(), ownWrites: OwnWriteLedger(),
            ingest: IngestActor(database: database, settings: settings), settings: settings,
            reporter: ErrorReporter(presenter: Presenter37(), sink: sink), ignoredApps: { [] }, access: AllowedPasteboardAccess(), sink: sink)
        let marker = "OC37-MARKER-TEXT"  // 16 bytes
        capture.start()

        // when a new text is copied, then the same text again, then a transient item
        board.copy([Self.text: Data(marker.utf8)]); capture.captureNow()
        await waitForProcessed(sink, 1)
        board.copy([Self.text: Data(marker.utf8)]); capture.captureNow()
        await waitForProcessed(sink, 2)
        board.copy([Self.text: Data("OC37-SECRET".utf8), Self.transient: Data("1".utf8)]); capture.captureNow()
        await waitForProcessed(sink, 3)
        await capture.stop()

        // then exactly 3 lines, in order: stored, deduped, skipped + CAP-POL-001
        let lines = sink.processed.map(\.publicText)
        #expect(lines == [
            "pasteboard.processed byteSize=16B kind=text outcome=stored",
            "pasteboard.processed byteSize=16B kind=text outcome=deduped",
            "pasteboard.processed byteSize=0B code=CAP-POL-001 outcome=skipped",
        ])
        // and no line, public or private, carries any clip content
        let everything = sink.all.map { "\($0.publicText) \($0.privateText)" }.joined(separator: "\n")
        #expect(!everything.contains("OC37-MARKER-TEXT"))
        #expect(!everything.contains("OC37-SECRET"))
        // and the stored item is the one row: the deduped copy bumped it, the transient copy never persisted
        let count = try await database.pool.read { try Int.fetchAll($0, sql: "SELECT COUNT(*) FROM item") }
        #expect(count == [1])
    }

    /// OC-0037's concealed half (TASK-503): a concealed copy now ends `stored` as a secure item, with its byte size and
    /// kind in the line and none of its content anywhere. Mutation: restore the old drop (skipped + CAP-POL-001): the
    /// outcome literal and the row count go red.
    @Test("OC-0037 a concealed copy logs stored as a secure item, no content")
    func concealedCopyLogsStored() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-oc0037c-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = SecureClipVault(store: MemoryKeychain())
        let database = try await FlotsamDatabase.open(folder: folder, secureVault: vault).get()
        let settings = SettingsStore(store: KV37())
        let board = Board37()
        let sink = Sink37()
        let capture = ClipboardCapture(
            pasteboard: board, sourceApps: App37(), ownWrites: OwnWriteLedger(),
            ingest: IngestActor(database: database, settings: settings), settings: settings,
            reporter: ErrorReporter(presenter: Presenter37(), sink: sink), ignoredApps: { [] }, access: AllowedPasteboardAccess(),
            vault: vault, sink: sink)
        capture.start()

        board.copy([Self.text: Data("OC37-SECRET".utf8), Self.concealed: Data("1".utf8)]); capture.captureNow()
        await waitForProcessed(sink, 1)
        await capture.stop()

        let lines = sink.processed.map(\.publicText)
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix("outcome=stored") == true)
        #expect(lines.first?.contains("CAP-POL-001") == false)
        let everything = sink.all.map { "\($0.publicText) \($0.privateText)" }.joined(separator: "\n")
        #expect(!everything.contains("OC37-SECRET"))
        let secure = try await database.pool.read { try Int.fetchAll($0, sql: "SELECT COUNT(*) FROM item WHERE isSecure = 1") }
        #expect(secure == [1])
    }
}
