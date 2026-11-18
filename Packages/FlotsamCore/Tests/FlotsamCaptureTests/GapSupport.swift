import Foundation
import GRDB
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

// Shared rig for the gap-closing suites (TASK-032/121/122, 115/116, 144, 147/148). Real ClipboardCapture,
// CaptureClassifier, IngestActor and a real database in a temp folder. Fakes sit only on the ports: the pasteboard,
// the source-app lookup, the settings key-value store, the error presenter and the log sink.

@MainActor
final class GapPasteboard: PasteboardPort {
    private var count = 1
    private var contents: [String: Data] = [:]
    /// How many times `changeCount` was read: one per poll tick (FR-001-01: a tick compares `changeCount` and nothing else).
    private(set) var changeCountReads = 0
    /// Wall-clock time of each `changeCount` read, so a test can measure the real tick interval.
    private(set) var changeCountReadTimes: [Date] = []
    private(set) var bytesRequested: [String] = []

    var changeCount: Int {
        changeCountReads += 1
        changeCountReadTimes.append(Date())
        return count
    }

    func copy(_ contents: [String: Data]) {
        self.contents = contents
        count += 1
    }

    func beginCopy() {
        contents = [:]
        count += 1
    }

    func finishCopy(_ contents: [String: Data]) { self.contents = contents }

    func currentTypeIdentifiers() -> [String] { contents.keys.sorted() }

    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        bytesRequested += types
        let reps = types.compactMap { uti in contents[uti].map { PasteboardRepresentation(uti: uti, data: $0) } }
        return .success(PasteboardSnapshot(changeCount: count, typeIdentifiers: currentTypeIdentifiers(), representations: reps))
    }

    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        copy(Dictionary(representations.map { ($0.uti, $0.data) }, uniquingKeysWith: { $1 }))
        return .success(count)
    }
}

@MainActor
struct GapSourceApps: SourceAppPort {
    var frontmost: SourceApp?
    func frontmostApp() -> SourceApp? { frontmost }
    func localizedName(forBundleId: String) -> String? { nil }
}

final class GapKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// Everything the reporter would draw: HUD text and Notice text and codes.
final class GapPresenter: ErrorPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var huds: [String] = []
    /// Every Notice list the user was ever shown, not only the latest: a Notice that cleared again (CAP-PRM-001 on
    /// resume, FR-001-18) was still shown.
    private var noticeHistory: [[Notice]] = []
    func showHUD(message: String) { lock.withLock { huds.append(message) } }
    func noticesChanged(_ notices: [Notice]) { lock.withLock { noticeHistory.append(notices) } }
    /// Every Notice list shown, oldest first.
    var noticeLists: [[Notice]] { lock.withLock { noticeHistory } }
    /// The Notices on screen now (what the list currently holds), as opposed to ever shown.
    var latestNotices: [Notice] { lock.withLock { noticeHistory.last ?? [] } }
    func presentFatal(_ error: FlotsamError) {}
    /// Everything the user would have been shown, as one string.
    var shown: String { lock.withLock { String(reflecting: huds) + String(reflecting: noticeHistory) } }
}

/// The log-sink seam (FR-000-09/10): keeps every record, whole.
final class GapSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { all.append(record) } }
    var records: [LogRecord] { lock.withLock { all } }
    /// Every field of every record, so a leak in any field (headline, public, private, message, cause) is found.
    var dump: String { records.map { String(reflecting: $0) }.joined(separator: "\n") }
}

struct GapRow: Equatable {
    let contentKey: String
    let plainText: String
    let copyCount: Int
}

@MainActor
final class GapRig {
    let folder: URL
    let database: FlotsamDatabase
    let pasteboard = GapPasteboard()
    let settings = SettingsStore(store: GapKV())
    let presenter = GapPresenter()
    let sink = GapSink()
    let reporter: ErrorReporter
    let capture: ClipboardCapture
    let ignored = GapIgnored()
    let ledger = OwnWriteLedger()
    /// Counts `itemsChanged` events: IngestActor publishes exactly one after each committed create or bump (FR-007-05).
    let itemsChangedCount = GapCounter()
    static let textType = "public.utf8-plain-text"

    static let frontmostBundle = "com.example.writer"

    init(pollTick: PollTick = PollTick(), scheduleTimer: @escaping ClipboardCapture.TimerScheduler = ClipboardCapture.systemTimer) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-gap-\(UUID().uuidString)")
        let sink = self.sink
        let presenter = self.presenter
        let pasteboard = self.pasteboard
        let settings = self.settings
        let ledger = self.ledger
        let ignored = self.ignored
        let database = try await FlotsamDatabase.open(folder: folder, logSink: sink).get()
        let reporter = ErrorReporter(presenter: presenter, sink: sink)
        let counter = itemsChangedCount
        database.events.subscribe { if $0 == .itemsChanged { counter.increment() } }
        self.folder = folder
        self.database = database
        self.reporter = reporter
        capture = ClipboardCapture(
            pasteboard: pasteboard,
            sourceApps: GapSourceApps(frontmost: SourceApp(bundleId: Self.frontmostBundle, name: "Writer")),
            ownWrites: ledger, ingest: IngestActor(database: database, settings: settings), settings: settings,
            reporter: reporter, ignoredApps: { ignored.value }, sink: sink, pollTick: pollTick,
            scheduleTimer: scheduleTimer)
    }

    /// Runs one poll, then waits until everything handed off has been ingested (stop drains the consumer).
    func settle() async {
        capture.captureNow()
        await capture.stop()
    }

    func cleanUp() async {
        await capture.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func text(_ string: String, markers: [String] = []) {
        var contents: [String: Data] = [Self.textType: Data(string.utf8)]
        for marker in markers { contents[marker] = Data() }
        pasteboard.copy(contents)
    }

    func itemCount() async -> Int {
        (try? await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") }) ?? -1
    }

    /// Rows read through a FRESH database instance on the same folder, never an in-memory array of what was written.
    func freshRows() async throws -> [GapRow] {
        let fresh = try await FlotsamDatabase.open(folder: folder).get()
        return try await fresh.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT contentKey, plainText, copyCount FROM item ORDER BY createdAt, rowid").map {
                GapRow(contentKey: $0["contentKey"], plainText: $0["plainText"] ?? "", copyCount: $0["copyCount"])
            }
        }
    }
}

final class GapIgnored: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Set<String> = []
    var value: Set<String> { get { lock.withLock { current } } set { lock.withLock { current = newValue } } }
}

final class GapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// Polls `condition` until it holds or `seconds` pass. For work that finishes on another executor (the capture
/// consumer, the unstructured error-report Task); returns whether the condition held, so a test asserts on it.
@MainActor
func eventually(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
