import FlotsamBase
import FlotsamPayload
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamShelf

// Blind QA of FR-006-14 / FR-006-18 as amended by S2: trimming a dropped bundle to the 500-member cap is reported by
// CAP-LIM-003 and is NOT "skipped": a drop trimmed that way and otherwise fully stored is a clean success, the
// `shelf.dropIn` line carries no error code, and `skippedFiles` stays 0. A genuinely unreadable file still counts.
// Real ShelfDropPlanner, real IngestActor over a real database, real ErrorReporter; fakes only for HUD, clock, KV, sink.

@MainActor
private final class HUDLog: ErrorPresenter {
    private(set) var messages: [String] = []
    func showHUD(message: String) { messages.append(message) }
    func noticesChanged(_ notices: [Notice]) {}
    func presentFatal(_ error: FlotsamError) {}
}

private final class KVStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class FixedClock: WallClock, @unchecked Sendable {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(for duration: Duration) async {}
}

private final class RecordingSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { stored.append(record) } }
    var dropLines: [String] { lock.withLock { stored.filter { $0.headline == "shelf.dropIn" }.map(\.publicContext) } }
}

@MainActor
private struct TrimBench {
    let root: URL
    let database: FlotsamDatabase
    let reporter: ErrorReporter
    let sink: RecordingSink
    let service: ShelfDropService

    init(sink: RecordingSink = RecordingSink()) async throws {
        self.sink = sink
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-captrim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("files"), withIntermediateDirectories: true)
        database = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data"), logSink: RecordingSink()).get()
        reporter = ErrorReporter(presenter: HUDLog(), clock: FixedClock(), sink: RecordingSink())
        let ingest = IngestActor(database: database, settings: SettingsStore(store: KVStore()))
        service = ShelfDropService(ingest: ingest, reporter: reporter, sink: sink, dropCompleted: {})
    }

    func cleanUp() {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("files").path) {
            for name in names {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("files/\(name)").path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func files(count: Int, unreadable: Int = 0) throws -> [URL] {
        (0..<(count + unreadable)).map { index in
            let url = root.appendingPathComponent("files/f\(String(format: "%04d", index)).txt")
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
            if index >= count { try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path) }
            return url
        }
    }

    func drop(_ urls: [URL]) async -> ShelfDropResult {
        let reps = urls.map { PasteboardRepresentation(uti: PasteboardTypes.fileURL, data: Data($0.absoluteString.utf8)) }
        return await service.drop(
            types: [PasteboardTypes.fileURL], representations: reps, source: nil, originatesInShelf: false,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func raised(_ code: ErrorCode) async -> Int { await reporter.recentErrors().filter { $0.code == code }.count }
    func rows() async throws -> [ItemRow] { try await database.items(matching: LibraryQuery()).get().rows }
}

@MainActor @Suite struct ShelfCapTrimBlindTests {
    // given exactly 500 readable files (the cap, nothing trimmed)
    // red if CAP-LIM-003 fires at the boundary (off-by-one on the ceiling)
    @Test("OC-S2-006-W22 a 500-file drop stores 500 members with no CAP-LIM-003 and a clean dropIn line")
    func exactlyAtCap() async throws {
        let sink = RecordingSink()
        let bench = try await TrimBench(sink: sink)
        defer { bench.cleanUp() }

        let result = await bench.drop(try bench.files(count: 500))

        guard case .stored(_, let skipped) = result else { Issue.record("expected stored, got \(result)"); return }
        #expect(skipped == 0)
        #expect(await bench.raised(.capLim003) == 0)
        #expect(try await bench.rows().map(\.memberCount) == [500])
        #expect(sink.dropLines == ["outcome=droppedIn"])
    }

    // given 501 readable files (one over the cap)
    // red if the trim is counted as skipped (skippedFiles 1, SHF-IO-001, a code on the dropIn line), or goes unreported
    @Test("OC-S2-006-W23 a 501-file drop is trimmed to 500, raises CAP-LIM-003 once, and is not skipped: no SHF-IO-001, no code on the dropIn line")
    func oneOverCap() async throws {
        let sink = RecordingSink()
        let bench = try await TrimBench(sink: sink)
        defer { bench.cleanUp() }

        let result = await bench.drop(try bench.files(count: 501))

        guard case .stored(_, let skipped) = result else { Issue.record("expected stored, got \(result)"); return }
        #expect(skipped == 0)
        #expect(await bench.raised(.capLim003) == 1)
        #expect(await bench.raised(.shfIo001) == 0)
        #expect(try await bench.rows().map(\.memberCount) == [500])
        #expect(sink.dropLines == ["outcome=droppedIn"])
    }

    // given 502 files of which 1 is unreadable (so 501 readable, trimmed to 500)
    // red if the trim and the skip are conflated: the skip must be counted and coded, the trim must not add to it
    @Test("OC-S2-006-W24 a trim plus one unreadable file counts exactly one skip, reports both codes, and the dropIn line carries only SHF-IO-001")
    func trimAndOneUnreadable() async throws {
        let sink = RecordingSink()
        let bench = try await TrimBench(sink: sink)
        defer { bench.cleanUp() }

        let result = await bench.drop(try bench.files(count: 501, unreadable: 1))

        guard case .stored(_, let skipped) = result else { Issue.record("expected stored, got \(result)"); return }
        #expect(skipped == 1)
        #expect(await bench.raised(.capLim003) == 1)
        #expect(await bench.raised(.shfIo001) == 1)
        #expect(try await bench.rows().map(\.memberCount) == [500])
        #expect(sink.dropLines == ["code=SHF-IO-001 outcome=stored"])
    }
}
