import AppKit
import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

// S2 harness (a): capture latency, from a pasteboard write to the stored, queryable row. Measurement only.
//
// The path is the production one: the App's `SystemPasteboard` adapter (symlinked into this target, so it is the real
// file) over a uniquely named PRIVATE NSPasteboard, read by the real `ClipboardCapture` on its real 0.5 s poll timer,
// classified by `CaptureClassifier`, ingested by `IngestActor` into a real GRDB database in a temporary folder. Faked:
// the source-app lookup, the settings key-value store and the error presenter. NSPasteboard.general is never touched
// (asserted below, and `SystemPasteboard` is always handed the private board explicitly).
//
// The measured interval (every figure below is a difference of two monotonic clock reads):
//   START  the instant before `SystemPasteboard.write` is called on the private pasteboard (the changeCount bump
//          happens inside that call, so the write itself is included).
//   END    the `itemsChanged` event, which `IngestActor` publishes right after the insert transaction commits, so the
//          row is readable from then on. Queryability is checked after the interval, outside the timing, through the
//          Library's own query API (`items(matching:)`), and a copy whose row is not found fails the test.
//   DETECT the first read of the pasteboard's type list after the write. That is the poll noticing the changeCount
//          change. It splits the interval: poll_wait = START..DETECT (waiting for the timer), persist = DETECT..END
//          (type list, gates, snapshot read, hand-off to the ingest consumer, classify + hash, insert, commit).
//
// Poll phase: the timer fires every 0.5 s (tolerance 0.1 s). If copies were issued right after each commit, every copy
// would land at the same phase and poll_wait would be a constant, not a distribution. So each copy is spaced by a
// deterministic pseudo-random 0 to 500 ms pause, which spreads the copy instant uniformly across the poll period.

private final class Stamp: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64?
    func set() { lock.withLock { if value == nil { value = nowNs() } } }
    func take() -> UInt64? { lock.withLock { defer { value = nil }; return value } }
}

/// `SystemPasteboard`, plus the time of the first type-list read after a write (the poll noticing the change).
@MainActor
private final class TimedPasteboard: PasteboardPort {
    private let inner: SystemPasteboard
    private(set) var detectedAt: UInt64?
    private var armed = false

    init(inner: SystemPasteboard) { self.inner = inner }

    /// Starts a copy: clears the last detection, and writes through the real adapter. Returns the START stamp.
    func timedWrite(_ representations: [PasteboardRepresentation]) -> (start: UInt64, result: FlotsamResult<Int>) {
        detectedAt = nil
        let start = nowNs()
        let result = inner.write(representations)
        armed = true
        return (start, result)
    }

    var changeCount: Int { inner.changeCount }

    func currentTypeIdentifiers() -> [String] {
        if armed, detectedAt == nil { detectedAt = nowNs() }
        return inner.currentTypeIdentifiers()
    }

    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> { inner.readSnapshot(types: types) }
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> { inner.write(representations) }
}

@MainActor
private struct FixedSourceApps: SourceAppPort {
    func frontmostApp() -> SourceApp? { SourceApp(bundleId: "com.example.perf", name: "Perf") }
    func localizedName(forBundleId bundleId: String) -> String? { nil }
}

private final class PerfKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class SilentPresenter: ErrorPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [ErrorCode] = []
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) { lock.withLock { codes.append(contentsOf: notices.map(\.code)) } }
    func presentFatal(_ error: FlotsamError) {}
    var noticeCodes: [ErrorCode] { lock.withLock { codes } }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct CaptureLatencyPerf {
    private static let copies = 200
    private static let warmups = 3

    @Test("PERF capture latency, 200 copies, private pasteboard to queryable row", .enabled(if: perfEnabled))
    func captureLatency() async throws {
        // given a private pasteboard (never .general), a real database, and the real capture on its real timer
        let board = NSPasteboard(name: NSPasteboard.Name("flotsam.perf.\(UUID().uuidString)"))
        #expect(board.name != NSPasteboard.general.name)
        defer { board.releaseGlobally() }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try await FlotsamDatabase.open(folder: folder).get()
        let settings = SettingsStore(store: PerfKV())
        let presenter = SilentPresenter()
        let pasteboard = TimedPasteboard(inner: SystemPasteboard(pasteboard: board))
        let capture = ClipboardCapture(
            pasteboard: pasteboard, sourceApps: FixedSourceApps(), ownWrites: OwnWriteLedger(),
            ingest: IngestActor(database: database, settings: settings),
            settings: settings, reporter: ErrorReporter(presenter: presenter), ignoredApps: { [] }, access: AllowedPasteboardAccess())
        let committed = Stamp()
        let unsubscribe = database.events.subscribe { if $0 == .itemsChanged { committed.set() } }
        defer { unsubscribe() }

        // a copy waits for its commit event; 10 s is a hang, not a slow copy
        func copy(_ index: Int, label: String) async throws -> (start: UInt64, detect: UInt64, end: UInt64, token: String) {
            // fixed width, so no token is a prefix of another (search matches prefixes)
            let token = "perfcopy-\(label)-" + String(format: "%04d", index)
            let text = "\(token) the quick brown fox jumps over the lazy dog, then files the quarterly report by email"
            _ = committed.take()
            let written = pasteboard.timedWrite([
                PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))
            ])
            try written.result.get()
            let deadline = nowNs() + 10_000_000_000
            while true {
                if let end = committed.take() {
                    let detect = try #require(pasteboard.detectedAt, "commit seen without the poll reading the board")
                    return (written.start, detect, end, token)
                }
                try #require(nowNs() < deadline, "copy \(label)-\(index) was not stored within 10 s")
                try await Task.sleep(for: .milliseconds(1))
            }
        }

        // the board must not be empty when capture starts (an empty first read counts toward privacy suspension)
        try pasteboard.write([PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("perf seed".utf8))]).get()
        capture.start()
        defer { Task { await capture.stop() } }
        try await Task.sleep(for: .seconds(1.2))

        // when 3 unmeasured warm-up copies run, then 200 measured copies, each at a pseudo-random point of the poll period
        for index in 1...Self.warmups { _ = try await copy(index, label: "warm") }
        var rng = SplitMix64(seed: 0xC0FFEE)
        var total: [Double] = []
        var pollWait: [Double] = []
        var persist: [Double] = []
        var tokens: [String] = []
        for index in 1...Self.copies {
            try await Task.sleep(for: .milliseconds(Int(rng.next() % 500)))
            let sample = try await copy(index, label: "run")
            total.append(milliseconds(from: sample.start, to: sample.end))
            pollWait.append(milliseconds(from: sample.start, to: sample.detect))
            persist.append(milliseconds(from: sample.detect, to: sample.end))
            tokens.append(sample.token)
        }

        // then every copy is a stored, queryable row (checked outside the timing, through the Library's query API)
        for token in tokens {
            let page = try await database.items(matching: LibraryQuery(filter: .all, text: token, sort: .recent, page: 0)).get()
            #expect(page.totalCount == 1, "\(token) not found by search")
        }
        #expect(try await database.count(filter: .all).get() == Self.copies + Self.warmups + 1)
        #expect(presenter.noticeCodes.isEmpty, "capture raised notices: \(presenter.noticeCodes)")
        #expect(total.count == Self.copies)

        printPerfLine("capture", [
            ("n", "\(Self.copies)"),
            ("p50_ms", fixed(percentile(total, 0.5))), ("p95_ms", fixed(percentile(total, 0.95))),
            ("mean_ms", fixed(mean(total))), ("max_ms", fixed(total.max() ?? 0)),
            ("poll_wait_p50_ms", fixed(percentile(pollWait, 0.5))), ("poll_wait_p95_ms", fixed(percentile(pollWait, 0.95))),
            ("persist_p50_ms", fixed(percentile(persist, 0.5))), ("persist_p95_ms", fixed(percentile(persist, 0.95))),
            ("persist_mean_ms", fixed(mean(persist))), ("persist_max_ms", fixed(persist.max() ?? 0)),
            ("warmups", "\(Self.warmups)"), ("poll_s", "\(PollTick.interval)"),
        ])
    }
}

/// Pasteboard reads allowed ("Paste from Other Apps" set to Allow): the access the capture tests run under unless a
/// test supplies its own stub.
private struct AllowedPasteboardAccess: PasteboardAccessPort {
    var isReadAllowed: Bool { true }
}
