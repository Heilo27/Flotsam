import Foundation
import GRDB
import XCTest
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

// FRD-001 clipboard capture through its real collaborators: ClipboardCapture, CaptureClassifier, IngestActor and a
// real database in a temp folder. Only the pasteboard, the source-app lookup and the settings store are fakes.

@MainActor
private final class FakePasteboard: PasteboardPort {
    private(set) var changeCount = 1
    private var contents: [String: Data] = [:]
    /// The type identifiers asked for in `readSnapshot`: a gate that rejects must not have read payload bytes.
    private(set) var bytesRequested: [String] = []

    func copy(_ contents: [String: Data]) {
        self.contents = contents
        changeCount += 1
    }

    /// What NSPasteboard does for a file copy: `clearContents` bumps `changeCount` and leaves the board empty, then
    /// `writeObjects` fills it WITHOUT a second bump (measured on a private pasteboard, TASK-401). A poll that lands
    /// between the two sees a new count and no types.
    func beginCopy() {
        contents = [:]
        changeCount += 1
    }

    func finishCopy(_ contents: [String: Data]) { self.contents = contents }

    func currentTypeIdentifiers() -> [String] { contents.keys.sorted() }

    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        bytesRequested += types
        let reps = types.compactMap { uti in contents[uti].map { PasteboardRepresentation(uti: uti, data: $0) } }
        return .success(PasteboardSnapshot(changeCount: changeCount, typeIdentifiers: currentTypeIdentifiers(), representations: reps))
    }

    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        copy(Dictionary(representations.map { ($0.uti, $0.data) }, uniquingKeysWith: { $1 }))
        return .success(changeCount)
    }
}

@MainActor
private struct FakeSourceApps: SourceAppPort {
    var frontmost: SourceApp?
    func frontmostApp() -> SourceApp? { frontmost }
    func localizedName(forBundleId: String) -> String? { nil }
}

private final class MemoryKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class RecordingPresenter: ErrorPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [ErrorCode] = []
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) { lock.withLock { codes.append(contentsOf: notices.map(\.code)) } }
    func presentFatal(_ error: FlotsamError) {}
    var noticeCodes: [ErrorCode] { lock.withLock { codes } }
}

@MainActor
final class ClipboardCaptureTests: XCTestCase {
    private var folder: URL!
    private var database: FlotsamDatabase!
    private var pasteboard: FakePasteboard!
    private var ledger: OwnWriteLedger!
    private var settings: SettingsStore!
    private var capture: ClipboardCapture!
    private var presenter: RecordingPresenter!
    private var ignored: Set<String> = []
    private let textType = "public.utf8-plain-text"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-capture-\(UUID().uuidString)")
        database = try await FlotsamDatabase.open(folder: folder).get()
        pasteboard = FakePasteboard()
        ledger = OwnWriteLedger()
        settings = SettingsStore(store: MemoryKV())
        ignored = []
        presenter = RecordingPresenter()
        capture = ClipboardCapture(
            pasteboard: pasteboard, sourceApps: FakeSourceApps(frontmost: SourceApp(bundleId: "com.example.writer", name: "Writer")),
            ownWrites: ledger, ingest: IngestActor(database: database, settings: settings), settings: settings,
            reporter: ErrorReporter(presenter: presenter), ignoredApps: { [unowned self] in ignored })
    }

    override func tearDown() async throws {
        await capture.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Runs one poll and waits until everything handed off has been ingested, then counts stored items.
    private func settle() async throws -> Int {
        capture.captureNow()
        await capture.stop()
        return try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") ?? -1 }
    }

    func testPlainTextCopyIsStored() async throws {
        capture.start()
        pasteboard.copy([textType: Data("hello flotsam".utf8)])
        let count = try await settle()
        XCTAssertEqual(count, 1)
        let text = try await database.pool.read { try String.fetchOne($0, sql: "SELECT plainText FROM item") }
        XCTAssertEqual(text, "hello flotsam")
    }

    func testOwnWriteIsNotCaptured() async throws {
        capture.start()
        _ = ledger.write([PasteboardRepresentation(uti: textType, data: Data("from the app".utf8))], to: pasteboard)
        let count = try await settle()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(pasteboard.bytesRequested.contains(textType), "payload bytes must not be read for an own write")
    }

    func testConcealedAndTransientAreNotCaptured() async throws {
        capture.start()
        pasteboard.copy([textType: Data("hunter2".utf8), PasteboardMarkers.concealed: Data()])
        capture.captureNow()
        pasteboard.copy([textType: Data("one-time".utf8), PasteboardMarkers.transient: Data()])
        let count = try await settle()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(pasteboard.bytesRequested.contains(textType))
    }

    func testIgnoredSourceAppIsNotCaptured() async throws {
        ignored = ["com.example.writer"]
        capture.start()
        pasteboard.copy([textType: Data("secret note".utf8)])
        let count = try await settle()
        XCTAssertEqual(count, 0)
    }

    func testCopyingTheSameTextTwiceBumpsInsteadOfDuplicating() async throws {
        capture.start()
        pasteboard.copy([textType: Data("same".utf8)])
        capture.captureNow()
        pasteboard.copy([textType: Data("other".utf8)])
        capture.captureNow()
        pasteboard.copy([textType: Data("same".utf8)])
        let count = try await settle()
        XCTAssertEqual(count, 2)
        let copies = try await database.pool.read {
            try Int.fetchOne($0, sql: "SELECT copyCount FROM item WHERE plainText = 'same'")
        }
        XCTAssertEqual(copies, 2)
    }

    func testPausedCaptureStoresNothing() async throws {
        settings.set(.paused, for: SettingKeys.captureMode)
        capture.start()
        pasteboard.copy([textType: Data("while paused".utf8)])
        let count = try await settle()
        XCTAssertEqual(count, 0)
    }

    // MARK: Copies caught mid-write (TASK-401)

    private func fileURLData(_ url: URL) -> Data { Data(url.absoluteString.utf8) }

    /// TASK-401. A Finder copy is `clearContents` (count bumps, board empty) then `writeObjects` (no second bump). A poll
    /// between the two used to mark that count processed, so the copy was dropped and nothing re-read it until the user
    /// copied something else.
    func testFileCopyPolledBetweenClearAndWriteIsStillCaptured() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-401-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        capture.start()

        pasteboard.beginCopy()
        capture.captureNow()  // lands in the window: the count is new, the board is empty
        pasteboard.finishCopy(["public.file-url": fileURLData(file)])
        let count = try await settle()  // the next poll, same count, now readable

        XCTAssertEqual(count, 1)
    }

    /// The S2 symptom: three file copies in a row each polled in the window, none captured. With the old code the third
    /// empty change also suspended capture (FR-001-18 b) and raised CAP-PRM-001 although access was never blocked.
    func testThreeCopiesEachPolledMidWriteAreAllCapturedAndDoNotSuspendCapture() async throws {
        capture.start()
        for n in 1...3 {
            pasteboard.beginCopy()
            capture.captureNow()
            pasteboard.finishCopy([textType: Data("copy \(n)".utf8)])
            capture.captureNow()
        }
        let count = try await settle()
        try await Task.sleep(nanoseconds: 200_000_000)  // reports are raised from unstructured tasks

        XCTAssertEqual(count, 3)
        XCTAssertFalse(presenter.noticeCodes.contains(.capPrm001), "a copy caught mid-write is not blocked access")
    }

    /// FR-001-18 b still holds: a change that stays empty across its re-reads counts, and three such changes suspend.
    func testThreeChangesThatStayEmptyStillSuspendCapture() async throws {
        capture.start()
        for _ in 1...3 {
            pasteboard.beginCopy()
            for _ in 1...ClipboardCapture.emptyAttemptsPerChange { capture.captureNow() }
        }
        for _ in 0..<100 where !presenter.noticeCodes.contains(.capPrm001) { try await Task.sleep(nanoseconds: 20_000_000) }

        XCTAssertTrue(presenter.noticeCodes.contains(.capPrm001))
    }
}
