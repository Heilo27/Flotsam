import Foundation
import GRDB
import XCTest
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

// TASK-400: one oversized copy raises CAP-LIM-003 exactly once, with the true count (FR-007-06, OC-0019, OC-7039).
// Runs the real IngestWorker (CaptureClassifier then IngestActor then ErrorReporter) over a real database; only the
// presenter is a fake. `recentErrors()` records every raise unthrottled, so a second raise cannot hide behind the
// Notice throttle.

@MainActor
private final class RecordingPresenter: ErrorPresenter {
    private(set) var notices: [Notice] = []
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) { self.notices = notices }
    func presentFatal(_ error: FlotsamError) {}
}

private final class CeilingKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private struct NullSink: LogSink {
    func write(_ record: LogRecord) {}
}

@MainActor
final class BundleCeilingRaiseTests: XCTestCase {
    private var folder: URL!
    private var files: URL!
    private var database: FlotsamDatabase!
    private var presenter: RecordingPresenter!
    private var reporter: ErrorReporter!
    private var worker: IngestWorker!

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-ceiling-\(UUID().uuidString)")
        folder = root.appendingPathComponent("data")
        files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        database = try await FlotsamDatabase.open(folder: folder).get()
        presenter = RecordingPresenter()
        reporter = ErrorReporter(presenter: presenter, sink: NullSink())
        let settings = SettingsStore(store: CeilingKV())
        worker = IngestWorker(
            ingest: IngestActor(database: database, settings: settings), reporter: reporter, sink: NullSink())
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: files.deletingLastPathComponent())
    }

    private func copy(_ count: Int, prefix: String) throws -> CapturedPayload {
        let reps = try (0..<count).map { index -> PasteboardRepresentation in
            let url = files.appendingPathComponent("\(prefix)-\(index).txt")
            try Data().write(to: url)
            return PasteboardRepresentation(uti: "public.file-url", data: Data(url.absoluteString.utf8))
        }
        return CapturedPayload(representations: reps, source: nil, capturedAt: Date(), origin: .pasteboard)
    }

    private func limitRaises() async -> Int {
        await reporter.recentErrors().filter { $0.code == .capLim003 }.count
    }

    private func memberCounts() async throws -> [Int] {
        try await database.pool.read { try Int.fetchAll($0, sql: "SELECT COUNT(*) FROM bundleMember GROUP BY itemId") }
    }

    func testOneOversizedCopyRaisesCapLim003OnceWithTheTrueCount() async throws {
        await worker.handle(try copy(501, prefix: "over"))

        let raises = await limitRaises()
        XCTAssertEqual(raises, 1, "one oversized copy must raise CAP-LIM-003 once")
        let notices = presenter.notices.filter { $0.code == .capLim003 }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.message.contains("501") == true, "message was: \(notices.first?.message ?? "none")")
        let counts = try await memberCounts()
        XCTAssertEqual(counts, [500], "behaviour kept: one bundle trimmed to its first 500 members")
    }

    func testExactlyTheCeilingRaisesNothing() async throws {
        await worker.handle(try copy(500, prefix: "exact"))

        let raises = await limitRaises()
        XCTAssertEqual(raises, 0)
        let counts = try await memberCounts()
        XCTAssertEqual(counts, [500])
    }
}
