import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
import FlotsamStorage
@testable import FlotsamShelf

// TASK-407 blind QA (FRD-006 FR-006-14, AC-006-16; FRD-007 FR-007-07). A drop whose ingest fails is reported as the
// Shelf's own code: CAP-VAL-001 (undecodable image, Info, log-only) becomes SHF-VAL-001 (HUD); every other ingest
// error passes through untouched. Expected values are literals only.

@MainActor
private final class Presenter: ErrorPresenter {
    private(set) var huds: [String] = []
    func showHUD(message: String) { huds.append(message) }
    func noticesChanged(_ notices: [Notice]) {}
    func presentFatal(_ error: FlotsamError) {}
}

private final class KV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class Clock: WallClock, @unchecked Sendable {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(for duration: Duration) async {}
}

private final class Sink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { stored.append(record) } }
    var records: [LogRecord] { lock.withLock { stored } }
}

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// An ingest that always fails with the error it is given, counting calls.
private final class FailingIngest: ShelfIngesting, @unchecked Sendable {
    let error: FlotsamError
    let calls = Tally()
    init(_ error: FlotsamError) { self.error = error }
    func ingest(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult> {
        calls.bump()
        return .failure(error)
    }
}

/// The real IngestActor, counting calls.
private final class CountingIngest: ShelfIngesting, @unchecked Sendable {
    let inner: IngestActor
    let calls = Tally()
    init(_ inner: IngestActor) { self.inner = inner }
    func ingest(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult> {
        calls.bump()
        return await inner.ingest(candidate)
    }
}

@MainActor
private struct Rig {
    let root: URL
    let database: FlotsamDatabase
    let presenter: Presenter
    let reporter: ErrorReporter
    let sink: Sink
    let completed: Tally
    let service: ShelfDropService
    let ingest: CountingIngest?
    let failing: FailingIngest?

    static func real() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worf407-\(UUID().uuidString)")
        let database = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data"), logSink: Sink()).get()
        let ingest = CountingIngest(IngestActor(database: database, settings: SettingsStore(store: KV())))
        return make(root: root, database: database, target: ingest, ingest: ingest, failing: nil)
    }

    static func failing(_ error: FlotsamError) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worf407-\(UUID().uuidString)")
        let database = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data"), logSink: Sink()).get()
        let stub = FailingIngest(error)
        return make(root: root, database: database, target: stub, ingest: nil, failing: stub)
    }

    private static func make(
        root: URL, database: FlotsamDatabase, target: any ShelfIngesting, ingest: CountingIngest?, failing: FailingIngest?
    ) -> Rig {
        let presenter = Presenter()
        let reporter = ErrorReporter(presenter: presenter, clock: Clock(), sink: Sink())
        let sink = Sink()
        let completed = Tally()
        let service = ShelfDropService(
            ingest: target, reporter: reporter, sink: sink, dropCompleted: { completed.bump() })
        return Rig(
            root: root, database: database, presenter: presenter, reporter: reporter, sink: sink, completed: completed,
            service: service, ingest: ingest, failing: failing)
    }

    func cleanUp() {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) { _ = names }
        try? FileManager.default.removeItem(at: root)
    }

    func drop(_ types: [String], _ reps: [PasteboardRepresentation]) async -> ShelfDropResult {
        await service.drop(
            types: types, representations: reps, source: nil, originatesInShelf: false,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func itemCount() async throws -> Int { try await database.count(filter: .all).get() }
    func rows() async throws -> [ItemRow] { try await database.items(matching: LibraryQuery()).get().rows }
    func raised(_ code: ErrorCode) async -> Int { await reporter.recentErrors().filter { $0.code == code }.count }
    var dropLines: [String] { sink.records.filter { $0.headline == "shelf.dropIn" }.map(\.publicContext) }
    var ingestCalls: Int { (ingest?.calls ?? failing?.calls)?.count ?? -1 }
}

private func code(_ result: ShelfDropResult) -> ErrorCode? {
    if case .failed(let error) = result { return error.code }
    return nil
}

private func junk(_ uti: String, _ bytes: [UInt8] = [0, 1, 2, 3]) -> PasteboardRepresentation {
    PasteboardRepresentation(uti: uti, data: Data(bytes))
}

private func textRep(_ s: String) -> PasteboardRepresentation {
    PasteboardRepresentation(uti: PasteboardTypes.plainText, data: Data(s.utf8))
}

@MainActor
@Suite struct Worf407ShelfIngestFailureAdversarialTests {
    // MARK: Pure mapping (ShelfDropPlanner.ingestFailure / nothingStorable)

    @Test("OC-WORF407-01 CAP-VAL-001 from ingest becomes SHF-VAL-001 with the Shelf's own message and no capture context")
    func capVal001Maps() {
        // given an ingest failure carrying the capture code and some context
        let incoming = FlotsamError(.capVal001, "Image data could not be decoded", context: [.count: .int(7)])
        // when mapped for the Shelf
        let mapped = ShelfDropPlanner.ingestFailure(incoming)
        // then it is the Shelf's refusal, verbatim
        expectFlotsamError(mapped, code: .shfVal001, message: "Drop holds nothing storable")
        #expect(mapped.severity == .warning, "SHF-VAL-001 is Warning, so the HUD shows (CAP-VAL-001 is Info, log-only)")
    }

    @Test("OC-WORF407-02 every other error code passes through ingestFailure unchanged, context included")
    func everyOtherCodePassesThrough() {
        // given each error code except CAP-VAL-001 (covers SSP-VAL-001, SHF-*, STO-*, CAP-LIM-*)
        var checked = 0
        for errorCode in ErrorCode.allCases where errorCode != .capVal001 {
            let incoming = FlotsamError(errorCode, "x", context: [.count: .int(3)])
            // when mapped
            let mapped = ShelfDropPlanner.ingestFailure(incoming)
            // then it is returned as-is
            #expect(mapped.code == errorCode, "code \(errorCode.rawValue) must not be remapped")
            #expect(mapped.context == [.count: .int(3)], "context of \(errorCode.rawValue) must survive")
            checked += 1
        }
        #expect(checked == ErrorCode.allCases.count - 1)
        #expect(checked > 50, "the sweep must cover the full catalogue, not a handful")
    }

    @Test("OC-WORF407-03 the screenshot code stays SSP-VAL-001; only the capture code is remapped")
    func screenshotCodeNotRemapped() {
        let mapped = ShelfDropPlanner.ingestFailure(FlotsamError(.sspVal001, "Image data could not be decoded"))
        #expect(mapped.code == .sspVal001)
        #expect(mapped.code != .shfVal001)
    }

    @Test("OC-WORF407-04 the classifier path and the ingest path give the same refusal (one home for the text)")
    func classifierAndIngestAgree() {
        // given a drop with an honoured type but an empty text body (classifier CAP-VAL-001)
        let planned = ShelfDropPlanner.plan(
            types: [PasteboardTypes.plainText], representations: [textRep("")], source: nil,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
        // when compared with the ingest mapping
        guard case .failure(let fromClassifier) = planned else {
            Issue.record("empty text must not plan"); return
        }
        let fromIngest = ShelfDropPlanner.ingestFailure(FlotsamError(.capVal001, "x"))
        // then identical code and text
        expectFlotsamError(fromClassifier, code: .shfVal001, message: "Drop holds nothing storable")
        expectFlotsamError(fromIngest, code: .shfVal001, message: "Drop holds nothing storable")
    }

    @Test("OC-WORF407-05 empty drop: no types, no representations is SHF-VAL-001 and fails at the planner")
    func emptyDropPlanner() {
        let planned = ShelfDropPlanner.plan(
            types: [], representations: [], source: nil, occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
        guard case .failure(let error) = planned else { Issue.record("empty drop must fail"); return }
        #expect(error.code == .shfVal001)
    }

    // MARK: Service routing, stubbed ingest failure for every code

    @Test("OC-WORF407-06 service reports CAP-VAL-001 from ingest as SHF-VAL-001: result, HUD, reporter, log, no completion")
    func serviceMapsCapVal001() async throws {
        // given an ingest that fails with the capture code
        let rig = try await Rig.failing(FlotsamError(.capVal001, "Image data could not be decoded"))
        defer { rig.cleanUp() }
        // when a PNG is dropped
        let result = await rig.drop([PasteboardTypes.png], [junk(PasteboardTypes.png)])
        // then the drop fails as SHF-VAL-001 everywhere the user or the log can see it
        #expect(code(result) == .shfVal001)
        #expect(rig.ingestCalls == 1)
        #expect(rig.presenter.huds == ["Flotsam can't store that kind of content."])
        #expect(await rig.raised(.shfVal001) == 1)
        #expect(await rig.raised(.capVal001) == 0)
        #expect(rig.dropLines == ["code=SHF-VAL-001 outcome=failed"])
        #expect(rig.completed.count == 0)
        #expect(try await rig.itemCount() == 0)
    }

    @Test("OC-WORF407-07 service passes every non-CAP-VAL-001 ingest failure through with its own code, log line and no completion")
    func serviceEveryOtherCode() async throws {
        var checked = 0
        for errorCode in ErrorCode.allCases where errorCode != .capVal001 {
            // given an ingest failing with this code
            let rig = try await Rig.failing(FlotsamError(errorCode, "x"))
            defer { rig.cleanUp() }
            // when anything storable is dropped
            let result = await rig.drop([PasteboardTypes.plainText], [textRep("hello")])
            // then that exact code comes back, is logged, and the drop is not completed
            #expect(code(result) == errorCode, "\(errorCode.rawValue)")
            #expect(rig.dropLines == ["code=\(errorCode.rawValue) outcome=failed"], "\(errorCode.rawValue)")
            #expect(rig.completed.count == 0)
            checked += 1
        }
        #expect(checked > 50)
    }

    // MARK: Real ingest, undecodable image data

    @Test("OC-WORF407-08 undecodable PNG, JPEG, TIFF, 0-byte and 1-byte image data: SHF-VAL-001 each, nothing stored")
    func undecodableMatrix() async throws {
        let cases: [(String, [UInt8])] = [
            (PasteboardTypes.png, [0, 1, 2, 3]),
            (PasteboardTypes.jpeg, [0xFF, 0xD8, 0x00]),
            (PasteboardTypes.tiff, [0x49, 0x49, 0x2A]),
            (PasteboardTypes.png, [0]),
            (PasteboardTypes.png, []),
        ]
        for (uti, bytes) in cases {
            // given a fresh library
            let rig = try await Rig.real()
            defer { rig.cleanUp() }
            // when undecodable image data is dropped
            let result = await rig.drop([uti], [junk(uti, bytes)])
            // then the drop fails as SHF-VAL-001 and the library is still empty
            #expect(code(result) == .shfVal001, "\(uti) \(bytes.count) bytes")
            #expect(try await rig.itemCount() == 0, "\(uti) \(bytes.count) bytes")
            #expect(rig.completed.count == 0)
            #expect(await rig.raised(.capVal001) == 0)
            #expect(rig.presenter.huds == ["Flotsam can't store that kind of content."], "\(uti) \(bytes.count) bytes")
        }
    }

    @Test("OC-WORF407-09 an undecodable drop after a good one leaves the stored item untouched (count and identity)")
    func failedDropLeavesSurvivor() async throws {
        // given one stored text item
        let rig = try await Rig.real()
        defer { rig.cleanUp() }
        let first = await rig.drop([PasteboardTypes.plainText], [textRep("survivor")])
        guard case .stored(let survivorId, let skipped) = first else { Issue.record("text must store"); return }
        #expect(skipped == 0)
        #expect(rig.completed.count == 1)
        // when an undecodable image is dropped
        let second = await rig.drop([PasteboardTypes.png], [junk(PasteboardTypes.png)])
        // then it fails, the count stays 1, the same row survives, completion is not signalled again
        #expect(code(second) == .shfVal001)
        let rows = try await rig.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.id == survivorId)
        #expect(rig.completed.count == 1)
        #expect(rig.dropLines.count == 2)
        #expect(rig.dropLines.last == "code=SHF-VAL-001 outcome=failed")
    }

    @Test("OC-WORF407-10 mixed drop, junk image plus text: the classifier stores the text as one item; no pair, no refusal")
    func mixedImageAndText() async throws {
        // given a drop declaring an image and text, the image being junk (the classifier picks the text: it never
        // reaches the image pipeline, so the ingest mapping is not involved)
        let rig = try await Rig.real()
        defer { rig.cleanUp() }
        // when dropped
        let result = await rig.drop(
            [PasteboardTypes.png, PasteboardTypes.plainText], [junk(PasteboardTypes.png), textRep("alongside")])
        // then exactly one item is stored (never a half-stored pair), the drop completes, and nothing is refused
        guard case .stored(let id, let skipped) = result else { Issue.record("expected stored, got \(result)"); return }
        #expect(skipped == 0)
        let rows = try await rig.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.id == id)
        #expect(rig.completed.count == 1)
        #expect(await rig.raised(.capVal001) == 0)
        #expect(await rig.raised(.shfVal001) == 0)
    }

    @Test("OC-WORF407-11 mixed files: 2 readable + 1 unreadable stores one bundle, skipped 1, one SHF-IO-001, no SHF-VAL-001")
    func mixedFilesStillPartial() async throws {
        // given three file URLs, one of which the readability probe refuses
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worf407f-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var urls: [URL] = []
        for name in ["a.bin", "b.bin", "gone.bin"] {
            let url = root.appendingPathComponent(name)
            try Data([1]).write(to: url)
            urls.append(url)
        }
        let rig = try await Rig.real()
        defer { rig.cleanUp() }
        let probeService = ShelfDropService(
            ingest: rig.ingest!, reporter: rig.reporter, sink: rig.sink,
            isReadable: { !$0.hasSuffix("gone.bin") }, dropCompleted: { rig.completed.bump() })
        // when dropped
        let result = await probeService.drop(
            types: [PasteboardTypes.fileURL],
            representations: urls.map { PasteboardRepresentation(uti: PasteboardTypes.fileURL, data: Data($0.absoluteString.utf8)) },
            source: nil, originatesInShelf: false, occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
        // then partially stored, the mapping did not touch the partial-success path
        guard case .stored(_, let skipped) = result else { Issue.record("must store: \(result)"); return }
        #expect(skipped == 1)
        #expect(try await rig.itemCount() == 1)
        #expect(await rig.raised(.shfIo001) == 1)
        #expect(await rig.raised(.shfVal001) == 0)
        #expect(rig.completed.count == 1)
    }

    @Test("OC-WORF407-12 empty drop through the service: SHF-VAL-001, ingest never called, nothing stored, one failed line")
    func emptyDropService() async throws {
        let rig = try await Rig.real()
        defer { rig.cleanUp() }
        let result = await rig.drop([], [])
        #expect(code(result) == .shfVal001)
        #expect(rig.ingestCalls == 0)
        #expect(try await rig.itemCount() == 0)
        #expect(rig.completed.count == 0)
        #expect(rig.dropLines == ["code=SHF-VAL-001 outcome=failed"])
    }

    @Test("OC-WORF407-13 a drag that began in the Shelf stays silent: no HUD, no ingest, no log even with image bytes")
    func ownDragStillSilent() async throws {
        let rig = try await Rig.real()
        defer { rig.cleanUp() }
        let result = await rig.service.drop(
            types: [PasteboardTypes.png], representations: [junk(PasteboardTypes.png)], source: nil,
            originatesInShelf: true, occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(result == .ignored)
        #expect(rig.ingestCalls == 0)
        #expect(rig.presenter.huds.isEmpty)
        #expect(rig.dropLines.isEmpty)
    }
}
