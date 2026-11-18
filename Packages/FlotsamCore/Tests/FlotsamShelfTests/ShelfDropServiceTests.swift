import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
import FlotsamStorage
@testable import FlotsamShelf

// FRD-006 FR-006-13, FR-006-14, FR-006-18 and AC-006-13 to AC-006-17, end to end below AppKit: the real
// ShelfDropPlanner, the real IngestActor over a real database in a scratch folder, the real ErrorReporter. Only the
// presenter, the key-value store, the clock and the log sink are fakes. The AppKit half of each OC (hover highlight,
// cursor, pasteboard reads, panel timing) is slice C2b's.

@MainActor
private final class RecordingPresenter: ErrorPresenter {
    private(set) var huds: [String] = []
    func showHUD(message: String) { huds.append(message) }
    func noticesChanged(_ notices: [Notice]) {}
    func presentFatal(_ error: FlotsamError) {}
}

private final class MemoryKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class ManualClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func sleep(for duration: Duration) async {}
}

private final class RecordingSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { stored.append(record) } }
    var records: [LogRecord] { lock.withLock { stored } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// The real IngestActor, remembering every candidate it was given and what came of it.
private final class RecordingIngest: ShelfIngesting, @unchecked Sendable {
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

/// A database whose write fails (FR-007-15).
private final class FailingIngest: ShelfIngesting, @unchecked Sendable {
    private let calls = Counter()
    var callCount: Int { calls.count }
    func ingest(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult> {
        calls.increment()
        return .failure(FlotsamError(.stoDb001, "Injected write failure"))
    }
}

@MainActor
private struct Rig {
    let root: URL
    let dataFolder: URL
    let files: URL
    let database: FlotsamDatabase
    let ingest: RecordingIngest
    let presenter: RecordingPresenter
    let reporter: ErrorReporter
    let clock: ManualClock
    let sink: RecordingSink
    let completed: Counter
    let service: ShelfDropService

    static func make(
        ingest override: (any ShelfIngesting)? = nil, isReadable: (@Sendable (String) -> Bool)? = nil
    ) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-drop-\(UUID().uuidString)")
        let dataFolder = root.appendingPathComponent("data")
        let files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let database = try await FlotsamDatabase.open(folder: dataFolder, logSink: RecordingSink()).get()
        let presenter = RecordingPresenter()
        let clock = ManualClock()
        let reporter = ErrorReporter(presenter: presenter, clock: clock, sink: RecordingSink())
        let ingest = RecordingIngest(IngestActor(database: database, settings: SettingsStore(store: MemoryKV())))
        let sink = RecordingSink()
        let completed = Counter()
        let target: any ShelfIngesting = override ?? ingest
        let service: ShelfDropService
        if let isReadable {
            service = ShelfDropService(
                ingest: target, reporter: reporter, sink: sink, isReadable: isReadable,
                dropCompleted: { completed.increment() })
        } else {
            service = ShelfDropService(
                ingest: target, reporter: reporter, sink: sink, dropCompleted: { completed.increment() })
        }
        return Rig(
            root: root, dataFolder: dataFolder, files: files, database: database, ingest: ingest, presenter: presenter,
            reporter: reporter, clock: clock, sink: sink, completed: completed, service: service)
    }

    func cleanUp() {
        // A test may leave a file with no permissions; it could not be deleted otherwise.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: files.path) {
            for name in names {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: files.appendingPathComponent(name).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Inputs

    func file(_ name: String, bytes: Int = 0) throws -> URL {
        let url = files.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    static func text(_ string: String) -> PasteboardRepresentation {
        PasteboardRepresentation(uti: PasteboardTypes.plainText, data: Data(string.utf8))
    }

    static func fileRep(_ url: URL) -> PasteboardRepresentation {
        PasteboardRepresentation(uti: PasteboardTypes.fileURL, data: Data(url.absoluteString.utf8))
    }

    static let textTypes = [PasteboardTypes.plainText]
    static let fileTypes = [PasteboardTypes.fileURL]

    @discardableResult
    func dropText(_ string: String, source: SourceApp? = nil, at seconds: TimeInterval = 0) async -> ShelfDropResult {
        await service.drop(
            types: Self.textTypes, representations: [Self.text(string)], source: source, originatesInShelf: false,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    @discardableResult
    func dropFiles(_ urls: [URL], source: SourceApp? = nil, at seconds: TimeInterval = 0) async -> ShelfDropResult {
        await service.drop(
            types: Self.fileTypes, representations: urls.map(Self.fileRep), source: source, originatesInShelf: false,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    // MARK: Observations

    func rows() async throws -> [ItemRow] { try await database.items(matching: LibraryQuery()).get().rows }
    func itemCount() async throws -> Int { try await database.count(filter: .all).get() }

    func dataFolderBytes() -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: dataFolder, includingPropertiesForKeys: keys) else { return 0 }
        return walker.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: Set(keys)).fileSize } }.reduce(0, +)
    }

    func raised(_ code: ErrorCode) async -> Int { await reporter.recentErrors().filter { $0.code == code }.count }

    var dropLines: [LogRecord] { sink.records.filter { $0.headline == "shelf.dropIn" } }
}

private func storedId(_ result: ShelfDropResult) -> UUID? {
    if case .stored(let id, _) = result { return id }
    return nil
}

private func failureCode(_ result: ShelfDropResult) -> ErrorCode? {
    if case .failed(let error) = result { return error.code }
    return nil
}

@MainActor
@Suite struct ShelfDropServiceTests {
    private let finder = SourceApp(bundleId: "com.apple.finder", name: "Finder")
    private let textEdit = SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")

    // MARK: Refusals (AC-006-13, FR-006-12)

    @Test("OC-6083 OC-6084 OC-6085 OC-6086 OC-6100 a refused drag is SHF-VAL-001 with the catalogue text and stores nothing")
    func refusedDragsStoreNothing() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let secret = [PasteboardTypes.plainText]
        let cases: [(types: [String], reps: [PasteboardRepresentation])] = [
            (["com.apple.NSFilePromiseItemMetadata", "com.apple.pasteboard.promised-file-url"], []),
            (["com.apple.cocoa.pasteboard.color"], []),
            (secret + [PasteboardMarkers.concealed], [Rig.text("secret-x")]),
            (secret + [PasteboardMarkers.transient], [Rig.text("secret-x")]),
            (secret + [PasteboardMarkers.autoGenerated], [Rig.text("secret-x")]),
            (["com.adobe.pdf"], [PasteboardRepresentation(uti: "com.adobe.pdf", data: Data([1, 2, 3]))]),
        ]
        for (index, drag) in cases.enumerated() {
            let result = await rig.service.drop(
                types: drag.types, representations: drag.reps, source: nil, originatesInShelf: false, occurredAt: Date())
            #expect(failureCode(result) == .shfVal001, "case \(index)")
        }
        #expect(try await rig.itemCount() == 0)
        #expect(try await rig.database.count(filter: .all, text: "secret-x").get() == 0)
        #expect(rig.ingest.candidates.isEmpty)
        #expect(rig.completed.count == 0)
        // One HUD for the code (60 s throttle), with the catalogue text; every refusal is still recorded.
        #expect(rig.presenter.huds == ["Flotsam can't store that kind of content."])
        #expect(await rig.raised(.shfVal001) == cases.count)
    }

    @Test("OC-6087 a Shelf card dragged back onto the Shelf is refused silently: no HUD, no ingest, no log")
    func ownDragIgnored() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let id = storedId(await rig.dropText("card", at: 0))
        let linesBefore = rig.sink.records.count
        let completedBefore = rig.completed.count

        let result = await rig.service.drop(
            types: Rig.textTypes, representations: [Rig.text("card")], source: nil, originatesInShelf: true, occurredAt: Date())

        #expect(result == .ignored)
        #expect(id != nil)
        #expect(try await rig.itemCount() == 1)
        #expect(rig.ingest.candidates.count == 1, "the own drag must not reach ingest, so the copy count cannot move")
        #expect(rig.presenter.huds.isEmpty)
        #expect(await rig.reporter.recentErrors().isEmpty)
        #expect(rig.sink.records.count == linesBefore)
        #expect(rig.completed.count == completedBefore)
    }

    // MARK: Accepted drops (FR-006-13, AC-006-14, AC-006-15)

    @Test("OC-6090 OC-6093 OC-6094 a drop stores whatever the capture mode or ignored list say, with the source recorded")
    func dropIgnoresCaptureMode() async throws {
        // The drop path has no capture-mode or ignored-apps input at all: Paused, Curated and an ignored source app
        // (TextEdit) all reach ingest the same way (FR-006-13, AC-006-15).
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let urls = try ["a.txt", "b.txt", "c.txt"].map { try rig.file($0) }

        let bundle = await rig.dropFiles(urls, source: finder, at: 1)
        let note = await rig.dropText("curated-drop", source: textEdit, at: 2)
        let ignored = await rig.dropText("ign-drop", source: textEdit, at: 3)

        #expect(storedId(bundle) != nil && storedId(note) != nil && storedId(ignored) != nil)
        let rows = try await rig.rows()
        #expect(rows.count == 3)
        let bundleRow = rows.first { $0.id == storedId(bundle) }
        #expect(bundleRow?.kind == .bundle)
        #expect(bundleRow?.memberCount == 3)
        #expect(bundleRow?.sourceName == "Finder")
        #expect(rows.first { $0.id == storedId(ignored) }?.sourceName == "TextEdit")
        #expect(try await rig.database.content(of: try #require(storedId(note))).get().plainText == "curated-drop")
        #expect(rows.first?.id == storedId(ignored), "the newest drop is at the top of Recent")
    }

    @Test("OC-6091 dropped URL text is stored as a link")
    func urlTextStoredAsLink() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let id = storedId(await rig.dropText("https://example.com/drop"))
        #expect(try await rig.rows().first { $0.id == id }?.kind == .link)
    }

    @Test("OC-6092 dropping the same three files again bumps that item to the top and adds no item")
    func sameFilesBump() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let urls = try ["a.txt", "b.txt", "c.txt"].map { try rig.file($0) }
        let first = storedId(await rig.dropFiles(urls, at: 1))
        await rig.dropText("newer", at: 2)
        #expect(try await rig.rows().first?.id != first)

        let again = storedId(await rig.dropFiles(urls, at: 3))

        #expect(again == first)
        #expect(try await rig.itemCount() == 2)
        #expect(try await rig.rows().first?.id == first)
        #expect(rig.ingest.results.last == .bumped(try #require(first)), "a bump is the copy count +1 (FR-007-03)")
    }

    @Test("OC-6095 a dropped folder is stored as a folder reference and the data folder grows by far less than it")
    func folderReference() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let folder = rig.files.appendingPathComponent("big", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 3 * 1024 * 1024).write(to: folder.appendingPathComponent("inner.bin"))
        let before = rig.dataFolderBytes()

        let id = storedId(await rig.dropFiles([folder]))

        #expect(try await rig.rows().first { $0.id == id }?.kind == .folder)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("inner.bin").path))
        #expect(rig.dataFolderBytes() - before < 1024 * 1024, "the folder's contents must not be copied into the store")
    }

    @Test("OC-6097 text dropped on the Shelf is stored as the kind the capture classifier gives the same text")
    func dropKindMatchesCapture() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let id = storedId(await rig.dropText("kind-probe@example.com"))
        let kind = try await rig.rows().first { $0.id == id }?.kind
        #expect(kind == .email)
        if case .success(let classification) = CaptureClassifier.classify([Rig.text("kind-probe@example.com")]) {
            #expect(kind == classification.kind)
        } else {
            Issue.record("the classifier rejected the probe text")
        }
    }

    @Test("OC-6106 a once-only drop is created once: its copy count is 1")
    func onceOnlyDrop() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let id = storedId(await rig.dropText("once-only"))
        #expect(try await rig.itemCount() == 1)
        #expect(rig.ingest.results == [.created(try #require(id))], "created, never bumped, so the copy count is 1 (AC-006-17)")
    }

    @Test("OC-6109 dropping text that already exists moves that item to the first Recent slot and adds none")
    func existingItemBumpedToTop() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let old = storedId(await rig.dropText("bump-me", at: 0))
        for index in 1...20 { await rig.dropText("filler \(index)", at: Double(index)) }
        let position = try await rig.rows().firstIndex { $0.id == old }
        #expect(position != nil && (position ?? 0) >= 15)

        let again = storedId(await rig.dropText("bump-me", at: 100))

        #expect(again == old)
        #expect(try await rig.itemCount() == 21)
        #expect(try await rig.rows().first?.id == old)
    }

    // MARK: Failures (FR-006-14, AC-006-16)

    @Test("OC-6098 a database write failure stores nothing and surfaces STO-DB-001")
    func writeFailure() async throws {
        let failing = FailingIngest()
        let rig = try await Rig.make(ingest: failing)
        defer { rig.cleanUp() }
        let url = try rig.file("a.txt")

        let result = await rig.dropFiles([url])

        #expect(failureCode(result) == .stoDb001)
        #expect(failing.callCount == 1)
        #expect(try await rig.itemCount() == 0)
        #expect(rig.presenter.huds == ["Flotsam couldn't save your history. Free up disk space and try again."])
        #expect(rig.completed.count == 0)
    }

    @Test("OC-6099 an unreadable file is skipped with SHF-IO-001, the others are stored, and no limit error is raised for a big file")
    func partialDropWithUnreadableFile() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let locked = try rig.file("locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let huge = try rig.file("huge.bin")
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 600 * 1024 * 1024)
        try handle.close()
        let ok = try rig.file("ok.txt")

        let result = await rig.dropFiles([locked, huge, ok])

        #expect(storedId(result) != nil)
        guard case .stored(_, let skipped) = result else { return }
        #expect(skipped == 1)
        let rows = try await rig.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .bundle)
        #expect(rows.first?.memberCount == 2, "files are held by reference and never size-checked (FR-007-06)")
        #expect(rig.presenter.huds == ["A dropped file couldn't be read and was skipped."])
        #expect(await rig.raised(.shfIo001) == 1)
        #expect(await rig.raised(.shfLim001) == 0)
        #expect(rig.dropLines.map(\.publicContext) == ["code=SHF-IO-001 outcome=stored"])
    }

    @Test("OC-6101 a file deleted during the drag is skipped with SHF-IO-001 and the remaining file is stored")
    func fileDeletedDuringDrag() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let gone = try rig.file("gone.txt")
        let kept = try rig.file("kept.txt")
        let reps = [gone, kept].map(Rig.fileRep)
        try FileManager.default.removeItem(at: gone)

        let result = await rig.service.drop(
            types: Rig.fileTypes, representations: reps, source: nil, originatesInShelf: false, occurredAt: Date())

        #expect(storedId(result) != nil)
        let rows = try await rig.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .file)
        #expect(rig.presenter.huds == ["A dropped file couldn't be read and was skipped."])
    }

    @Test("OC-6101 when every dropped file is gone nothing is stored and SHF-IO-001 is surfaced")
    func everyFileGone() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let gone = try rig.file("gone.txt")
        let reps = [Rig.fileRep(gone)]
        try FileManager.default.removeItem(at: gone)

        let result = await rig.service.drop(
            types: Rig.fileTypes, representations: reps, source: nil, originatesInShelf: false, occurredAt: Date())

        #expect(failureCode(result) == .shfIo001)
        #expect(try await rig.itemCount() == 0)
        #expect(rig.presenter.huds.count == 1)
        #expect(rig.completed.count == 0)
    }

    @Test("OC-6102 two drops each skipping a file 10 s apart show the SHF-IO-001 HUD once and still record both")
    func unreadableHUDThrottled() async throws {
        let rig = try await Rig.make(isReadable: { !$0.hasSuffix("locked.txt") })
        defer { rig.cleanUp() }
        let locked = try rig.file("locked.txt")
        let first = try rig.file("one.txt")
        let second = try rig.file("two.txt")

        await rig.dropFiles([locked, first], at: 1)
        rig.clock.advance(by: 10)
        await rig.dropFiles([locked, second], at: 2)

        #expect(rig.presenter.huds == ["A dropped file couldn't be read and was skipped."])
        #expect(await rig.raised(.shfIo001) == 2)
        #expect(try await rig.itemCount() == 2)
    }

    @Test("OC-6103 two readable files are stored as a bundle with no error")
    func twoReadableFilesNoError() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let urls = try ["a.txt", "b.txt"].map { try rig.file($0) }

        let id = storedId(await rig.dropFiles(urls))

        let row = try await rig.rows().first { $0.id == id }
        #expect(row?.kind == .bundle)
        #expect(row?.memberCount == 2)
        #expect(rig.presenter.huds.isEmpty)
        #expect(await rig.reporter.recentErrors().isEmpty)
        #expect(rig.dropLines.map(\.publicContext) == ["outcome=droppedIn"])
    }

    @Test("FR-007-06 a bundle trimmed to the member ceiling is stored, its CAP-LIM-003 warning is reported, and it is not a partial drop")
    func trimmedBundleIsNotPartial() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let urls = try (0...IngestLimits.maxBundleMembers).map { try rig.file("f\($0).txt") }

        let result = await rig.dropFiles(urls)

        guard case .stored(_, let skipped) = result else {
            Issue.record("expected the trimmed bundle to be stored, got \(result)")
            return
        }
        #expect(skipped == 0)
        #expect(await rig.raised(.capLim003) == 1)
        #expect(rig.dropLines.map(\.publicContext) == ["outcome=droppedIn"])
    }

    @Test("OC-6104 dropped text over the 10 MiB ceiling stores nothing and surfaces SHF-LIM-001 with the limit")
    func oversizedText() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }

        let result = await rig.dropText(String(repeating: "a", count: IngestLimits.maxTextBytes + 1))

        #expect(failureCode(result) == .shfLim001)
        #expect(try await rig.itemCount() == 0)
        #expect(rig.presenter.huds.count == 1)
        #expect(rig.presenter.huds.first?.hasPrefix("A dropped item was too large to save (over ") == true)
        #expect(rig.presenter.huds.first?.contains("10") == true)
        #expect(rig.completed.count == 0)
    }

    @Test("OC-6104 dropped image data over the 100 MiB ceiling stores nothing and surfaces SHF-LIM-001")
    func oversizedImage() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let image = PasteboardRepresentation(uti: PasteboardTypes.png, data: Data(count: IngestLimits.maxImageBytes + 1))

        let result = await rig.service.drop(
            types: [PasteboardTypes.png], representations: [image], source: nil, originatesInShelf: false, occurredAt: Date())

        #expect(failureCode(result) == .shfLim001)
        #expect(try await rig.itemCount() == 0)
    }

    // MARK: Hold and log (FR-006-15, FR-006-18, AC-006-17, AC-006-19)

    @Test("OC-6105 OC-6110 dropCompleted is signalled once per stored or bumped drop and never for a failure or own drag")
    func dropCompletedSignal() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }

        await rig.dropText("held", at: 1)
        #expect(rig.completed.count == 1)
        await rig.dropText("held", at: 2)
        #expect(rig.completed.count == 2, "a bump is also a completed drop")

        await rig.service.drop(
            types: ["com.adobe.pdf"], representations: [], source: nil, originatesInShelf: false, occurredAt: Date())
        await rig.service.drop(
            types: Rig.textTypes, representations: [Rig.text("x")], source: nil, originatesInShelf: true, occurredAt: Date())
        #expect(rig.completed.count == 2)
    }

    @Test("OC-6117 a drop writes one shelf.dropIn line carrying its outcome and, when refused, the error code")
    func dropLogLine() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        await rig.dropText("fine")
        await rig.service.drop(
            types: ["com.adobe.pdf"], representations: [], source: nil, originatesInShelf: false, occurredAt: Date())

        #expect(rig.dropLines.map(\.publicContext) == ["outcome=droppedIn", "code=SHF-VAL-001 outcome=failed"])
    }

    @Test("OC-6118 the drop line and the errors it raises carry neither dropped text nor file names")
    func dropLogIsPrivacySafe() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let url = try rig.file("zz-marker-file.txt")
        await rig.dropText("zz-marker-text", source: textEdit)
        await rig.dropFiles([url, rig.files.appendingPathComponent("zz-marker-gone.txt")], source: textEdit)

        #expect(!rig.dropLines.isEmpty)
        for record in rig.sink.records {
            let everything = [record.headline, record.publicContext, record.privateContext, record.message ?? ""].joined(separator: " ")
            for marker in ["zz-marker-file", "zz-marker-text", "zz-marker-gone", "TextEdit"] {
                #expect(!everything.contains(marker), "\(marker) leaked into \(record.headline)")
            }
        }
    }
}
