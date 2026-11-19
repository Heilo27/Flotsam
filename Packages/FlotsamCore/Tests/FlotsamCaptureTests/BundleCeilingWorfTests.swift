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
private final class WorfRecordingPresenter: ErrorPresenter {
    private(set) var notices: [Notice] = []
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) { self.notices = notices }
    func presentFatal(_ error: FlotsamError) {}
}

private final class WorfKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private struct WorfNullSink: LogSink {
    func write(_ record: LogRecord) {}
}

@MainActor
final class BundleCeilingWorfTests: XCTestCase {
    private var root: URL!
    private var files: URL!
    private var database: FlotsamDatabase!
    private var presenter: WorfRecordingPresenter!
    private var reporter: ErrorReporter!
    private var worker: IngestWorker!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-worf400-\(UUID().uuidString)")
        files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        database = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data")).get()
        presenter = WorfRecordingPresenter()
        reporter = ErrorReporter(presenter: presenter, sink: WorfNullSink())
        worker = IngestWorker(
            ingest: IngestActor(database: database, settings: SettingsStore(store: WorfKV())), reporter: reporter,
            sink: WorfNullSink())
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func url(_ name: String) throws -> URL {
        let u = files.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: u.path) { try Data().write(to: u) }
        return u
    }

    private func payload(_ names: [String]) throws -> CapturedPayload {
        let reps = try names.map {
            PasteboardRepresentation(uti: "public.file-url", data: Data(try url($0).absoluteString.utf8))
        }
        return CapturedPayload(representations: reps, source: nil, capturedAt: Date(), origin: .pasteboard)
    }

    private func names(_ range: Range<Int>, last: String? = nil) -> [String] {
        var all = range.map { "f-\($0).txt" }
        if let last { all[all.count - 1] = last }
        return all
    }

    private func limitNotices() -> [Notice] { presenter.notices.filter { $0.code == .capLim003 } }

    private func items() async throws -> [(copyCount: Int, members: Int)] {
        try await database.pool.read {
            try Row.fetchAll($0, sql: """
                SELECT i.copyCount AS c, (SELECT COUNT(*) FROM bundleMember m WHERE m.itemId = i.id) AS n
                FROM item i ORDER BY i.createdAt, i.id
                """).map { ($0["c"] as Int, $0["n"] as Int) }
        }
    }

    // OC-7039 + FR-001-15 (contentKey = every standardised path). given two 501-file copies identical in the first
    // 500 and different only in the 501st; when both are copied; then two distinct bundles, each trimmed to 500, and
    // a raise for each oversized event. Red if CaptureClassifier hashes only the first 500 paths again.
    func testTwoOversizedCopiesDifferingOnlyBeyondTheCeilingAreTwoItems() async throws {
        await worker.handle(try payload(names(0..<501)))
        await worker.handle(try payload(names(0..<501, last: "other-tail.txt")))

        let all = try await items()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.members), [500, 500])
        XCTAssertEqual(all.map(\.copyCount), [1, 1])
        // Two oversized events, two raises (the Notice list itself throttles a repeated code to one entry).
        let raises = await reporter.recentErrors().filter { $0.code == .capLim003 }.count
        XCTAssertEqual(raises, 2)
    }

    // given the same 501-file copy twice; then one item, copyCount 2, still 500 members, and no second notice
    // (FR-007-05 step 1 bumps before limits). Red if the bump path ran limits and raised again, or contentKey was
    // unstable.
    func testRecopyingTheIdenticalOversizedBundleBumpsAndRaisesNothingNew() async throws {
        await worker.handle(try payload(names(0..<501)))
        await worker.handle(try payload(names(0..<501)))

        let all = try await items()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.map(\.copyCount), [2])
        XCTAssertEqual(all.map(\.members), [500])
        XCTAssertEqual(limitNotices().count, 1)
        let raises = await reporter.recentErrors().filter { $0.code == .capLim003 }.count
        XCTAssertEqual(raises, 1)
    }

    // 502 files: the notice carries the true count 502, not 501 and not 500; stored 500. Red if the count is
    // hard-coded or derived from the ceiling.
    func testTheNoticeCarriesTheTrueCountForAnotherSize() async throws {
        await worker.handle(try payload(names(0..<502)))

        let notices = limitNotices()
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.message.contains("502") == true, notices.first?.message ?? "none")
        XCTAssertFalse(notices.first?.message.contains("501") == true)
        let all = try await items()
        XCTAssertEqual(all.map(\.members), [500])
    }

    // OC-7039 second half in sequence: 501 then exactly 500 (different files) => two items, still only one notice.
    func testAnExactlyFullBundleAfterAnOversizedOneAddsNoNotice() async throws {
        await worker.handle(try payload(names(0..<501)))
        await worker.handle(try payload(names(1000..<1500)))

        let all = try await items()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.members), [500, 500])
        XCTAssertEqual(limitNotices().count, 1)
    }

    // TASK-402, FR-001-12 + FR-007-06, end to end through the real IngestWorker and a fresh read of the database.
    // given a 501-file copy (capture bookmarks only the first 500; member 501 is kept by path alone); when ingested;
    // then item count +1, exactly 500 members stored (the first 500 in pasteboard order, member 501 absent, every
    // stored member with a bookmark), and exactly one CAP-LIM-003 raise whose count is 501. Red if capture drops the
    // 501st member (the raise would say 500 or not fire), if the ceiling moves out of ingest (stored 501), or if the
    // bookmark cap is applied so low that a stored member loses its bookmark.
    func testA501PathCaptureStoresFiveHundredMembersAndRaisesWithCount501() async throws {
        let expected = names(0..<501).map { files.appendingPathComponent($0).standardizedFileURL.path }

        await worker.handle(try payload(names(0..<501)))

        let stored = try await database.pool.read { db -> [(path: String, hasBookmark: Bool)] in
            try Row.fetchAll(db, sql: "SELECT path, bookmark FROM bundleMember ORDER BY ordinal")
                .map { ($0["path"] as String, ($0["bookmark"] as Data?) != nil) }
        }
        let paths = stored.map(\.path)
        let bookmarkless = stored.filter { !$0.hasBookmark }.count
        let itemCount = try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") }
        XCTAssertEqual(itemCount, 1)
        XCTAssertEqual(stored.count, 500)
        XCTAssertEqual(paths, Array(expected.prefix(500)))
        XCTAssertFalse(paths.contains(expected[500]))
        XCTAssertEqual(bookmarkless, 0)

        let raises = await reporter.recentErrors().filter { $0.code == .capLim003 }
        XCTAssertEqual(raises.count, 1)
        XCTAssertTrue(limitNotices().first?.message.contains("501") == true, limitNotices().first?.message ?? "none")
    }

    // OC-0019: no file name leaks into the notice text.
    func testTheNoticeNeverContainsAFileName() async throws {
        await worker.handle(try payload(names(0..<501, last: "FLOTSAM-MARK-6B.txt")))

        let notices = limitNotices()
        XCTAssertEqual(notices.count, 1)
        XCTAssertFalse(notices.first?.message.contains("FLOTSAM-MARK-6") == true)
    }
}
