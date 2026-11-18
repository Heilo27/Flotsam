import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

// Independent verification of TASK-401 (FRD-001 FR-001-01 re-read, FR-001-18 b, FR-001-22, AC-001-15, AC-001-18).
// Written without reference to the builder's tests. Every sequence is driven by `captureNow()` with no suspension point
// between calls, so the real 0.5 s timer that `start()` installs cannot interleave. Each `captureNow()` is one tick.
// Expected values are literals only.

private final class ScriptedBoard: PasteboardPort {
    private(set) var changeCount = 1
    private var contents: [String: Data] = [:]
    var failReads = false
    private(set) var snapshotReads = 0

    /// `clearContents`: count bumps, board empty.
    func clear() { contents = [:]; changeCount += 1 }
    /// `writeObjects`: fills with no second bump.
    func fill(_ new: [String: Data]) { contents = new }
    /// An atomic copy: one bump and the data.
    func copy(_ new: [String: Data]) { contents = new; changeCount += 1 }

    func currentTypeIdentifiers() -> [String] { contents.keys.sorted() }
    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        snapshotReads += 1
        if failReads { return .failure(FlotsamError(.capOs001, "scripted read failure")) }
        let reps = types.compactMap { uti in contents[uti].map { PasteboardRepresentation(uti: uti, data: $0) } }
        return .success(PasteboardSnapshot(changeCount: changeCount, typeIdentifiers: currentTypeIdentifiers(), representations: reps))
    }
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        copy(Dictionary(representations.map { ($0.uti, $0.data) }, uniquingKeysWith: { $1 }))
        return .success(changeCount)
    }
}

@MainActor
private struct Writer: SourceAppPort {
    func frontmostApp() -> SourceApp? { SourceApp(bundleId: "com.example.writer", name: "Writer") }
    func localizedName(forBundleId: String) -> String? { nil }
}

private final class KV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class Sink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { records.append(record) } }
    func count(containing text: String) -> Int { lock.withLock { records.filter { $0.publicText.contains(text) }.count } }
}

private final class Presenter: ErrorPresenter, @unchecked Sendable {
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) {}
    func presentFatal(_ error: FlotsamError) {}
}

@MainActor
private struct Rig {
    let folder: URL
    let database: FlotsamDatabase
    let board: ScriptedBoard
    let sink: Sink
    let capture: ClipboardCapture

    static func make(ignored: Set<String> = []) async throws -> Rig {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-worf401-\(UUID().uuidString)")
        let database = try await FlotsamDatabase.open(folder: folder).get()
        let settings = SettingsStore(store: KV())
        let board = ScriptedBoard()
        let sink = Sink()
        let capture = ClipboardCapture(
            pasteboard: board, sourceApps: Writer(), ownWrites: OwnWriteLedger(),
            ingest: IngestActor(database: database, settings: settings), settings: settings,
            reporter: ErrorReporter(presenter: Presenter(), sink: sink), ignoredApps: { ignored }, sink: sink)
        return Rig(folder: folder, database: database, board: board, sink: sink, capture: capture)
    }

    /// Ticks the poll once.
    func tick(_ times: Int = 1) { for _ in 0..<times { capture.captureNow() } }

    func texts() async throws -> [String] {
        await capture.stop()
        return try await database.pool.read { try String.fetchAll($0, sql: "SELECT plainText FROM item ORDER BY plainText") }
    }

    func copyCounts() async throws -> [Int] {
        try await database.pool.read { try Int.fetchAll($0, sql: "SELECT copyCount FROM item ORDER BY plainText") }
    }

    /// Reports are raised from unstructured tasks; give them time to reach the sink.
    func drain() async throws { try await Task.sleep(nanoseconds: 300_000_000) }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

private let text = "public.utf8-plain-text"
private func data(_ s: String) -> [String: Data] { [text: Data(s.utf8)] }

// MARK: (1) no double store, no lost or merged later change

@MainActor
@Suite("TASK-401 worf: retry stores once")
struct ClipboardRetryStoresOnceWorfTests {
    @Test("OC-401-W1 a board that fills on retry tick 1 is stored exactly once, however long polling continues")
    func fillsOnRetryTick1() async throws {
        // given a copy caught between clear and write
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.clear()
        rig.tick()
        // when the board fills before the next tick and polling carries on for many ticks
        rig.board.fill(data("alpha"))
        rig.tick(6)
        // then one item exists, copied once, and the payload was read from the board exactly once
        #expect(try await rig.texts() == ["alpha"])
        #expect(try await rig.copyCounts() == [1])
        #expect(rig.board.snapshotReads == 1)
    }

    @Test("OC-401-W2 a board that fills on retry tick 2 is stored exactly once")
    func fillsOnRetryTick2() async throws {
        // given a copy caught empty on two consecutive ticks
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.clear()
        rig.tick(2)
        // when it fills before the third read and polling carries on
        rig.board.fill(data("beta"))
        rig.tick(6)
        // then one item, one copy, one read
        #expect(try await rig.texts() == ["beta"])
        #expect(try await rig.copyCounts() == [1])
        #expect(rig.board.snapshotReads == 1)
    }

    @Test("OC-401-W3 a board that fills only after all three reads came back empty is not captured by the retry")
    func fillsAfterTheWindowIsNotCaptured() async throws {
        // given a change that stayed empty for the first read and both retries
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.clear()
        rig.tick(3)
        // when data lands on the same count afterwards
        rig.board.fill(data("late"))
        rig.tick(4)
        // then the window has closed: nothing stored (FR-001-01: three reads in all)
        #expect(try await rig.texts() == [])
    }

    @Test("OC-401-W4 a real change during the retry window is stored, the abandoned empty one is not, and nothing is merged")
    func laterRealChangeDuringWindow() async throws {
        // given an empty change on its first read
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.clear()
        rig.tick()
        // when a different, complete copy arrives before the retry
        rig.board.copy(data("gamma"))
        rig.tick(5)
        // then exactly that copy is stored, once
        #expect(try await rig.texts() == ["gamma"])
        #expect(try await rig.copyCounts() == [1])
    }

    @Test("OC-401-W5 a copy that fills on retry and a real copy right after it are two separate items")
    func fillThenNewCopyAreNotMerged() async throws {
        // given the first copy captured on its retry tick
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.clear()
        rig.tick()
        rig.board.fill(data("one"))
        rig.tick()
        // when a second copy follows on the very next tick
        rig.board.copy(data("two"))
        rig.tick(4)
        // then both are stored, each once
        #expect(try await rig.texts() == ["one", "two"])
        #expect(try await rig.copyCounts() == [1, 1])
    }

    @Test("OC-401-W6 an empty change superseded by a second empty change that then fills captures only the second")
    func supersededEmptyChangeThenFill() async throws {
        // given two clears in a row with a poll after each
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.clear()
        rig.tick()
        rig.board.clear()
        rig.tick()
        // when the second one fills
        rig.board.fill(data("second"))
        rig.tick(5)
        // then exactly one item, the filled one
        #expect(try await rig.texts() == ["second"])
        #expect(try await rig.copyCounts() == [1])
    }
}

// MARK: (2) concealed / transient mid-write

@MainActor
@Suite("TASK-401 worf: markers that land mid-write")
struct ClipboardRetryMarkersWorfTests {
    @Test("OC-401-W7 concealed type appearing on the retry tick is honoured: nothing stored, no payload byte read",
          arguments: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"])
    func markerOnRetryIsNeverStored(marker: String) async throws {
        // given an empty first read
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.clear()
        rig.tick()
        // when the board fills with a password-shaped payload plus the marker, and polling continues
        rig.board.fill([text: Data("hunter2".utf8), marker: Data()])
        rig.tick(6)
        // then nothing was stored and no payload was read
        #expect(try await rig.texts() == [])
        #expect(rig.board.snapshotReads == 0)
    }

    @Test("OC-401-W8 the marker skip is logged once for one change, not once per tick afterwards (control: atomic copy)")
    func markerSkipLoggedOnce() async throws {
        // control: the same copy arriving atomically, polled for 6 ticks
        let control = try await Rig.make()
        defer { control.cleanUp() }
        control.capture.start()
        control.board.copy([text: Data("hunter2".utf8), "org.nspasteboard.ConcealedType": Data()])
        control.tick(6)
        #expect(control.sink.count(containing: "CAP-POL-001") == 1, "control: observation of the skip must work")

        // given the marker lands on the retry tick
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.clear()
        rig.tick()
        rig.board.fill([text: Data("hunter2".utf8), "org.nspasteboard.ConcealedType": Data()])
        // when polling continues on the same changeCount
        rig.tick(6)
        // then one change is skipped once
        withKnownIssue("DEFECT TASK-401-F1: rereadingChangeCount is not cleared on the skip/raise early exits, so the same changeCount is re-handled every tick. Remove this wrapper when fixed.") { #expect(rig.sink.count(containing: "CAP-POL-001") == 1) }
    }
}

// MARK: (3) suspension still works, and only for persistent emptiness

@MainActor
@Suite("TASK-401 worf: CAP-PRM-001")
struct ClipboardRetrySuspensionWorfTests {
    @Test("OC-401-W9 three persistently empty changes raise CAP-PRM-001 once; two do not")
    func threePersistentEmptyChangesSuspend() async throws {
        // given two changes that stay empty across all their reads
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        for _ in 1...2 { rig.board.clear(); rig.tick(3) }
        try await rig.drain()
        // then not yet suspended
        #expect(rig.sink.count(containing: "CAP-PRM-001") == 0)

        // when a third persistently empty change arrives
        rig.board.clear(); rig.tick(3)
        try await rig.drain()
        // then CAP-PRM-001 is raised exactly once
        #expect(rig.sink.count(containing: "CAP-PRM-001") == 1)

        // and a fourth does not raise it again
        rig.board.clear(); rig.tick(3)
        try await rig.drain()
        #expect(rig.sink.count(containing: "CAP-PRM-001") == 1)
    }

    @Test("OC-401-W10 the third empty change is not counted until its third read")
    func thirdChangeCountsOnItsThirdRead() async throws {
        // given two persistent empties
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        for _ in 1...2 { rig.board.clear(); rig.tick(3) }
        // when the third is read twice only
        rig.board.clear(); rig.tick(2)
        try await rig.drain()
        // then no suspension yet
        #expect(rig.sink.count(containing: "CAP-PRM-001") == 0)
        // and the third read tips it
        rig.tick()
        try await rig.drain()
        #expect(rig.sink.count(containing: "CAP-PRM-001") == 1)
    }

    @Test("OC-401-W11 one empty change followed by a real copy never suspends, even repeated many times")
    func emptyThenRealCopyNeverSuspends() async throws {
        // given the pattern empty-change, real copy, repeated five times
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        for n in 1...5 {
            rig.board.clear(); rig.tick(3)
            rig.board.copy(data("real \(n)")); rig.tick()
        }
        try await rig.drain()
        // then never suspended and all five real copies stored
        #expect(rig.sink.count(containing: "CAP-PRM-001") == 0)
        #expect(try await rig.texts().count == 5)
    }

    @Test("OC-401-W12 a real copy between the second and third persistent empties resets the count")
    func realCopyResetsTheCount() async throws {
        // given two persistent empties, a real copy, then two more persistent empties
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        for _ in 1...2 { rig.board.clear(); rig.tick(3) }
        rig.board.copy(data("real")); rig.tick()
        for _ in 1...2 { rig.board.clear(); rig.tick(3) }
        try await rig.drain()
        // then no suspension: four empties in all, but never three in a row
        #expect(rig.sink.count(containing: "CAP-PRM-001") == 0)
    }

    @Test("OC-401-W13 after suspension a readable change resumes capture and stores it")
    func resumesAfterSuspension() async throws {
        // given suspended capture
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        for _ in 1...3 { rig.board.clear(); rig.tick(3) }
        // when access returns and the user copies
        rig.board.copy(data("back"))
        rig.tick(2)
        // then it is stored
        #expect(try await rig.texts() == ["back"])
    }
}

// MARK: (4) FR-001-22 and the other early exits must not repeat once a retry has happened

@MainActor
@Suite("TASK-401 worf: early exits after a retry")
struct ClipboardRetryEarlyExitWorfTests {
    @Test("OC-401-W14 no honoured type after a retry: CAP-VAL-001 raised once for one change (control: atomic)")
    func noHonouredTypeRaisedOnce() async throws {
        let control = try await Rig.make()
        defer { control.cleanUp() }
        control.capture.start()
        control.board.copy(["com.example.unhonoured": Data("x".utf8)])
        control.tick(6)
        try await control.drain()
        #expect(control.sink.count(containing: "CAP-VAL-001") == 1, "control: observation must work")

        // given an empty first read, then an unhonoured type
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.clear()
        rig.tick()
        rig.board.fill(["com.example.unhonoured": Data("x".utf8)])
        // when polling continues on the same changeCount
        rig.tick(6)
        try await rig.drain()
        // then the change is dropped once (FR-001-22: the next tick proceeds normally)
        withKnownIssue("DEFECT TASK-401-F1: rereadingChangeCount is not cleared on the skip/raise early exits, so the same changeCount is re-handled every tick. Remove this wrapper when fixed.") { #expect(rig.sink.count(containing: "CAP-VAL-001") == 1) }
    }

    @Test("OC-401-W15 read failure after a retry: CAP-OS-001 raised once, not on every tick (control: atomic)")
    func readFailureRaisedOnce() async throws {
        let control = try await Rig.make()
        defer { control.cleanUp() }
        control.capture.start()
        control.board.failReads = true
        control.board.copy(data("x"))
        control.tick(6)
        try await control.drain()
        #expect(control.sink.count(containing: "CAP-OS-001") == 1, "control: observation must work")

        // given an empty first read, then a readable type whose read throws
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.failReads = true
        rig.board.clear()
        rig.tick()
        rig.board.fill(data("x"))
        // when polling continues
        rig.tick(6)
        try await rig.drain()
        // then one failed change raises one error
        withKnownIssue("DEFECT TASK-401-F1: rereadingChangeCount is not cleared on the skip/raise early exits, so the same changeCount is re-handled every tick. Remove this wrapper when fixed.") { #expect(rig.sink.count(containing: "CAP-OS-001") == 1) }
        #expect(try await rig.texts() == [])
    }

    @Test("OC-401-W16 ignored source app after a retry: skipped once (control: atomic)")
    func ignoredAppSkippedOnce() async throws {
        let control = try await Rig.make(ignored: ["com.example.writer"])
        defer { control.cleanUp() }
        control.capture.start()
        control.board.copy(data("x"))
        control.tick(6)
        #expect(control.sink.count(containing: "CAP-POL-002") == 1, "control: observation must work")

        let rig = try await Rig.make(ignored: ["com.example.writer"])
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.clear()
        rig.tick()
        rig.board.fill(data("x"))
        rig.tick(6)
        withKnownIssue("DEFECT TASK-401-F1: rereadingChangeCount is not cleared on the skip/raise early exits, so the same changeCount is re-handled every tick. Remove this wrapper when fixed.") { #expect(rig.sink.count(containing: "CAP-POL-002") == 1) }
        #expect(try await rig.texts() == [])
    }

    @Test("OC-401-W17 a read failure on the first tick of a normal copy still does not touch the retry state")
    func failureThenNextCopyStillCaptured() async throws {
        // given a failed read on a complete copy
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        rig.capture.start()
        rig.board.failReads = true
        rig.board.copy(data("bad"))
        rig.tick(2)
        // when reads recover and the next copy arrives
        rig.board.failReads = false
        rig.board.copy(data("good"))
        rig.tick(2)
        // then the next copy is stored
        #expect(try await rig.texts() == ["good"])
    }
}
