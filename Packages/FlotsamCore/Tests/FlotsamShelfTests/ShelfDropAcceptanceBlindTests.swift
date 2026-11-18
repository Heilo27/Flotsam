import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
import FlotsamStorage
@testable import FlotsamShelf

// Blind QA of FRD-006 slice 5 (C2a): FR-006-12/13/14, AC-006-13, AC-006-16, SHF-LIM-001, SHF-IO-001, SHF-VAL-001.
// Written from the FRD and the contract, not from the implementation. Real planner, real IngestActor over a real
// database in a scratch folder, real ErrorReporter; only the presenter, clock, key-value store and log sink are fakes.

@MainActor
private final class HUDs: ErrorPresenter {
    private(set) var messages: [String] = []
    func showHUD(message: String) { messages.append(message) }
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

private final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class Spy: ShelfIngesting, @unchecked Sendable {
    private let inner: IngestActor
    private let lock = NSLock()
    private var seen: [IngestCandidate] = []
    private var outcomes: [IngestOutcome] = []
    init(_ inner: IngestActor) { self.inner = inner }
    func ingest(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult> {
        lock.withLock { seen.append(candidate) }
        let result = await inner.ingest(candidate)
        if case .success(let value) = result { lock.withLock { outcomes.append(value.outcome) } }
        return result
    }
    var candidates: [IngestCandidate] { lock.withLock { seen } }
    var results: [IngestOutcome] { lock.withLock { outcomes } }
}

@MainActor
private struct Bench {
    let root: URL
    let files: URL
    let database: FlotsamDatabase
    let spy: Spy
    let presenter: HUDs
    let reporter: ErrorReporter
    let sink: Sink
    let signals: Signals
    let service: ShelfDropService

    static func make() async throws -> Bench {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-blind-\(UUID().uuidString)")
        let files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let database = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data"), logSink: Sink()).get()
        let presenter = HUDs()
        let reporter = ErrorReporter(presenter: presenter, clock: Clock(), sink: Sink())
        let spy = Spy(IngestActor(database: database, settings: SettingsStore(store: KV())))
        let sink = Sink()
        let signals = Signals()
        let service = ShelfDropService(ingest: spy, reporter: reporter, sink: sink, dropCompleted: { signals.bump() })
        return Bench(
            root: root, files: files, database: database, spy: spy, presenter: presenter, reporter: reporter,
            sink: sink, signals: signals, service: service)
    }

    func cleanUp() {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: files.path) {
            for name in names {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: files.appendingPathComponent(name).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func file(_ name: String, sparseBytes: Int = 0) throws -> URL {
        let url = files.appendingPathComponent(name)
        try Data().write(to: url)
        if sparseBytes > 0 {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(sparseBytes))
            try handle.close()
        }
        return url
    }

    func locked(_ name: String) throws -> URL {
        let url = try file(name)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        return url
    }

    static func fileRep(_ url: URL) -> PasteboardRepresentation {
        PasteboardRepresentation(uti: PasteboardTypes.fileURL, data: Data(url.absoluteString.utf8))
    }

    static func textRep(_ string: String) -> PasteboardRepresentation {
        PasteboardRepresentation(uti: PasteboardTypes.plainText, data: Data(string.utf8))
    }

    func drop(
        types: [String], _ reps: [PasteboardRepresentation], own: Bool = false
    ) async -> ShelfDropResult {
        await service.drop(
            types: types, representations: reps, source: nil, originatesInShelf: own,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func dropFiles(_ urls: [URL]) async -> ShelfDropResult {
        await drop(types: [PasteboardTypes.fileURL], urls.map(Self.fileRep))
    }

    func rows() async throws -> [ItemRow] { try await database.items(matching: LibraryQuery()).get().rows }
    func raised(_ code: ErrorCode) async -> Int { await reporter.recentErrors().filter { $0.code == code }.count }
}

private func code(of result: ShelfDropResult) -> ErrorCode? {
    if case .failed(let error) = result { return error.code }
    return nil
}

@MainActor
@Suite struct ShelfDropAcceptanceBlindTests {
    // MARK: Gate 3 markers (FR-006-13 b, AC-006-13)

    @Test("OC-6085 OC-6086 a marker on a FILE drop refuses it with SHF-VAL-001 and stores nothing, not just on a text drop")
    func markerOnFileDropRefused() async throws {
        // given a real readable file dragged together with each never-store marker
        // when it is dropped
        // then it is refused with SHF-VAL-001 and neither an item nor an ingest call happens
        // (red if the marker check only guarded the text path, or ran after file classification)
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        let url = try bench.file("secret.txt")
        for marker in PasteboardMarkers.neverStore {
            let result = await bench.drop(types: [PasteboardTypes.fileURL, marker], [Bench.fileRep(url)])
            #expect(code(of: result) == .shfVal001, "\(marker)")
        }
        #expect(try await bench.rows().isEmpty)
        #expect(bench.spy.candidates.isEmpty)
        #expect(bench.signals.count == 0)
        #expect(bench.presenter.messages == ["Flotsam can't store that kind of content."])
    }

    @Test("OC-6087 a Shelf-origin drag is silent even when it would otherwise be refused: no SHF-VAL-001 is raised for it")
    func ownDragOfUnstorableTypesIsSilent() async throws {
        // given a drag that began in the Shelf and carries only a PDF, and one carrying a Concealed marker
        // when each is dropped back
        // then nothing is raised, shown or logged (red if the own-drag check ran after the type check)
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        let pdf = await bench.drop(types: ["com.adobe.pdf"], [], own: true)
        let concealed = await bench.drop(
            types: [PasteboardTypes.plainText, PasteboardMarkers.concealed], [Bench.textRep("s")], own: true)

        #expect(pdf == .ignored)
        #expect(concealed == .ignored)
        #expect(bench.presenter.messages.isEmpty)
        #expect(await bench.reporter.recentErrors().isEmpty)
        #expect(bench.spy.candidates.isEmpty)
    }

    // MARK: Files and folders never size-checked (FR-006-14, SHF-LIM-001)

    @Test("FR-006-14 a single file one byte over the 100 MiB image ceiling is stored as a file with no limit error")
    func singleHugeFileStored() async throws {
        // given one readable sparse file of 100 MiB + 1 and another of 10 MiB + 1 (each just over a ceiling)
        // when dropped separately
        // then each is stored as kind file and SHF-LIM-001 is never raised
        // (red if a size ceiling were applied to file members)
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        let over100 = try bench.file("over100.bin", sparseBytes: 100 * 1024 * 1024 + 1)
        let over10 = try bench.file("over10.bin", sparseBytes: 10 * 1024 * 1024 + 1)

        let first = await bench.dropFiles([over100])
        let second = await bench.dropFiles([over10])

        for result in [first, second] {
            guard case .stored(_, let skipped) = result else {
                Issue.record("expected a stored drop, got \(result)")
                continue
            }
            #expect(skipped == 0)
        }
        let rows = try await bench.rows()
        #expect(rows.count == 2)
        #expect(rows.map(\.kind) == [.file, .file])
        #expect(await bench.raised(.shfLim001) == 0)
        #expect(bench.presenter.messages.isEmpty)
    }

    @Test("OC-6104 text of exactly 10 MiB is stored; one byte more is SHF-LIM-001 whose HUD names the limit as 10 MB (catalogue rendering, OC-0019)")
    func textCeilingBoundary() async throws {
        // given text at the ceiling and text one byte over
        // when dropped
        // then the first is stored (count 1) and the second is refused naming the limit, count unchanged
        // (red if the comparison were >= instead of >, or the limit were not filled in)
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        let atLimit = String(repeating: "a", count: 10 * 1024 * 1024)
        let over = String(repeating: "b", count: 10 * 1024 * 1024 + 1)

        let stored = await bench.drop(types: [PasteboardTypes.plainText], [Bench.textRep(atLimit)])
        let refused = await bench.drop(types: [PasteboardTypes.plainText], [Bench.textRep(over)])

        guard case .stored = stored else {
            Issue.record("text at the ceiling must be stored, got \(stored)")
            return
        }
        #expect(code(of: refused) == .shfLim001)
        #expect(try await bench.rows().count == 1)
        #expect(bench.presenter.messages == ["A dropped item was too large to save (over 10 MB)."])
        #expect(bench.signals.count == 1)
    }

    @Test("OC-6104 an oversized text drop does not hide a stored sibling: the refusal is logged with its code and nothing is stored")
    func oversizedTextLogsCode() async throws {
        // given text over the ceiling
        // when dropped
        // then exactly one shelf.dropIn line carries code=SHF-LIM-001 outcome=failed
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        _ = await bench.drop(
            types: [PasteboardTypes.plainText], [Bench.textRep(String(repeating: "c", count: 10 * 1024 * 1024 + 1))])
        let lines = bench.sink.records.filter { $0.headline == "shelf.dropIn" }.map(\.publicContext)
        #expect(lines == ["code=SHF-LIM-001 outcome=failed"])
    }

    // MARK: Unreadable files (FR-006-14, SHF-IO-001, AC-006-16)

    @Test("OC-6101 every one of three dropped files unreadable stores nothing and shows exactly one SHF-IO-001 HUD")
    func allThreeUnreadable() async throws {
        // given three files, none readable
        // when dropped together
        // then the drop fails with SHF-IO-001, nothing is stored, one HUD, no completion signal
        // (red if all-unreadable fell through to ingest or were reported as SHF-VAL-001)
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        let urls = try ["a.txt", "b.txt", "c.txt"].map { try bench.locked($0) }

        let result = await bench.dropFiles(urls)

        #expect(code(of: result) == .shfIo001)
        #expect(try await bench.rows().isEmpty)
        #expect(bench.spy.candidates.isEmpty)
        #expect(bench.presenter.messages == ["A dropped file couldn't be read and was skipped."])
        #expect(bench.signals.count == 0)
        #expect(await bench.raised(.shfVal001) == 0)
    }

    @Test("OC-6099 two unreadable of three files: the lone readable file is stored as a single file item and each skip is recorded")
    func twoOfThreeUnreadable() async throws {
        // given two unreadable files and one readable
        // when dropped together
        // then one file item (not a bundle) is stored, skippedFiles == 2, two SHF-IO-001 recorded, one HUD
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        let lockedA = try bench.locked("a.txt")
        let lockedB = try bench.locked("b.txt")
        let ok = try bench.file("ok.txt")

        let result = await bench.dropFiles([lockedA, ok, lockedB])

        guard case .stored(_, let skipped) = result else {
            Issue.record("expected a partial store, got \(result)")
            return
        }
        #expect(skipped == 2)
        let rows = try await bench.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .file)
        #expect(rows.first?.memberCount == 1)
        #expect(await bench.raised(.shfIo001) == 2)
        #expect(bench.presenter.messages == ["A dropped file couldn't be read and was skipped."])
        #expect(bench.signals.count == 1)
    }

    @Test("OC-6099 a readable folder dropped with an unreadable file is kept as a folder member, the file skipped")
    func folderSurvivesUnreadableSibling() async throws {
        // given a readable folder and an unreadable file
        // when dropped together
        // then the folder is stored alone as a folder reference with one skipped file
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        let folder = bench.files.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let locked = try bench.locked("locked.txt")

        let result = await bench.dropFiles([folder, locked])

        guard case .stored(_, let skipped) = result else {
            Issue.record("expected a partial store, got \(result)")
            return
        }
        #expect(skipped == 1)
        #expect(try await bench.rows().map(\.kind) == [.folder])
    }

    // MARK: Classification parity with capture (FR-006-13)

    @Test("OC-6109 text already captured from the clipboard is bumped, not duplicated, when dropped")
    func dropBumpsClipboardCapturedItem() async throws {
        // given text ingested through the clipboard-capture mapping (origin .pasteboard)
        // when the same text is dropped
        // then ingest reports a bump of that same id and the library still holds one item
        // (red if the drop computed a different contentKey or origin took part in dedupe)
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        guard case .success(let classification) = CaptureClassifier.classify([Bench.textRep("shared across capture and drop")]) else {
            Issue.record("classifier rejected the probe")
            return
        }
        let captured = IngestCandidate(
            classification: classification, source: nil, origin: .pasteboard,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
        let first = await bench.spy.ingest(captured)
        guard case .success(let firstResult) = first, case .created(let firstId) = firstResult.outcome else {
            Issue.record("capture ingest did not create an item: \(first)")
            return
        }

        let result = await bench.drop(types: [PasteboardTypes.plainText], [Bench.textRep("shared across capture and drop")])

        guard case .stored(let id, _) = result else {
            Issue.record("expected stored, got \(result)")
            return
        }
        #expect(id == firstId)
        #expect(bench.spy.results.last == .bumped(firstId))
        #expect(try await bench.rows().count == 1)
    }

    @Test("FR-001-08 files win over text on a mixed Finder-style drop: the file is stored and the file name text is not")
    func fileBeatsTextOnMixedDrop() async throws {
        // given a drop carrying a file URL and a plain-text file name
        // when dropped
        // then a file item is stored and no text item is created
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        let url = try bench.file("report.txt")

        let result = await bench.drop(
            types: [PasteboardTypes.fileURL, PasteboardTypes.plainText],
            [Bench.fileRep(url), Bench.textRep("report.txt")])

        guard case .stored = result else {
            Issue.record("expected stored, got \(result)")
            return
        }
        let rows = try await bench.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .file)
    }

    // MARK: Boundary and negative cases

    @Test("FR-006-14 whitespace-only text is an accepted type with nothing storable: SHF-VAL-001, nothing stored")
    func whitespaceOnlyTextRefused() async throws {
        // given text that is only whitespace
        // when dropped
        // then SHF-VAL-001 (not a capture code) and no item
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        let result = await bench.drop(types: [PasteboardTypes.plainText], [Bench.textRep("  \n\t ")])
        #expect(code(of: result) == .shfVal001)
        #expect(try await bench.rows().isEmpty)
        #expect(bench.spy.candidates.isEmpty)
    }

    @Test("FR-007-07 a dropped PNG that cannot be decoded stores nothing and signals no completed drop (CAP-VAL-001 by source)")
    func undecodableImageStoresNothing() async throws {
        // given PNG-typed bytes that are not an image
        // when dropped
        // then the drop fails with CAP-VAL-001, nothing is stored, no completion signal.
        // (HUD deliberately not asserted: CAP-VAL-001 is Info, so FR-000-04 makes it log-only; see the QA report.)
        let bench = try await Bench.make()
        defer { bench.cleanUp() }
        let junk = PasteboardRepresentation(uti: PasteboardTypes.png, data: Data([0, 1, 2, 3]))

        let result = await bench.drop(types: [PasteboardTypes.png], [junk])

        #expect(code(of: result) == .capVal001)
        #expect(try await bench.rows().isEmpty)
        #expect(bench.signals.count == 0)
        #expect(bench.spy.candidates.isEmpty == false, "the bytes reach ingest: the refusal comes from decoding, not from the classifier")
    }
}
