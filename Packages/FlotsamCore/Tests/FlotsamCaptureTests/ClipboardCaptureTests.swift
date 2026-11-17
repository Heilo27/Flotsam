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

@MainActor
private final class NullPresenter: ErrorPresenter {
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) {}
    func presentFatal(_ error: FlotsamError) {}
}

@MainActor
final class ClipboardCaptureTests: XCTestCase {
    private var folder: URL!
    private var database: FlotsamDatabase!
    private var pasteboard: FakePasteboard!
    private var ledger: OwnWriteLedger!
    private var settings: SettingsStore!
    private var capture: ClipboardCapture!
    private var ignored: Set<String> = []
    private let textType = "public.utf8-plain-text"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-capture-\(UUID().uuidString)")
        database = try await FlotsamDatabase.open(folder: folder).get()
        pasteboard = FakePasteboard()
        ledger = OwnWriteLedger()
        settings = SettingsStore(store: MemoryKV())
        ignored = []
        capture = ClipboardCapture(
            pasteboard: pasteboard, sourceApps: FakeSourceApps(frontmost: SourceApp(bundleId: "com.example.writer", name: "Writer")),
            ownWrites: ledger, ingest: IngestActor(database: database, settings: settings), settings: settings,
            reporter: ErrorReporter(presenter: NullPresenter()), ignoredApps: { [unowned self] in ignored })
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
}
