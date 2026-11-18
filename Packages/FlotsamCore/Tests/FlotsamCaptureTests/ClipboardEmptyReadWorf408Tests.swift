import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

// Independent adversarial verification of TASK-408 (FRD-001 FR-001-18 b, AC-001-15): a change whose types are listed
// but whose snapshot yields no bytes counts toward the same empty-read threshold as an empty type list.
// Every sequence is driven by `captureNow()` with no suspension point between calls, so the real 0.5 s timer cannot
// interleave. One `captureNow()` is one tick; a change that reads empty is watched for `emptyChangeWatchLimit` on a manual clock
// and counts as empty when that watch ends (`expire()`), or when a newer change supersedes it.
// Expected values are literals only.

private final class Board408: PasteboardPort {
    private(set) var changeCount = 1
    private var contents: [String: Data] = [:]
    /// Types are listed but the bytes read back empty (a gated board).
    var emptyBytes = false
    private(set) var snapshotReads = 0

    func clear() { contents = [:]; changeCount += 1 }
    func fill(_ new: [String: Data]) { contents = new }
    func copy(_ new: [String: Data]) { contents = new; changeCount += 1 }

    func currentTypeIdentifiers() -> [String] { contents.keys.sorted() }
    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        snapshotReads += 1
        let reps = emptyBytes ? [] : types.compactMap { uti in contents[uti].map { PasteboardRepresentation(uti: uti, data: $0) } }
        return .success(PasteboardSnapshot(changeCount: changeCount, typeIdentifiers: currentTypeIdentifiers(), representations: reps))
    }
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> { copy([:]); return .success(changeCount) }
}

@MainActor
private struct App408: SourceAppPort {
    func frontmostApp() -> SourceApp? { SourceApp(bundleId: "com.example.writer", name: "Writer") }
    func localizedName(forBundleId: String) -> String? { nil }
}

private final class KV408: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class Sink408: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { records.append(record) } }
    func count(containing text: String) -> Int { lock.withLock { records.filter { $0.publicText.contains(text) }.count } }
}

private final class Presenter408: ErrorPresenter, @unchecked Sendable {
    func showHUD(message: String) {}
    func noticesChanged(_ notices: [Notice]) {}
    func presentFatal(_ error: FlotsamError) {}
}

@MainActor
private struct Rig408 {
    let folder: URL
    let database: FlotsamDatabase
    let board: Board408
    let sink: Sink408
    let capture: ClipboardCapture
    let settings: SettingsStore
    let clock: ManualClock
    let reporter: ErrorReporter

    static func make(ignored: Set<String> = []) async throws -> Rig408 {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-worf408-\(UUID().uuidString)")
        let database = try await FlotsamDatabase.open(folder: folder).get()
        let settings = SettingsStore(store: KV408())
        let board = Board408()
        let sink = Sink408()
        let clock = ManualClock()
        let reporter = ErrorReporter(presenter: Presenter408(), sink: sink)
        // Inert timer: the test ticks by hand, and a real 0.5 s tick would add a read of its own.
        let capture = ClipboardCapture(
            pasteboard: board, sourceApps: App408(), ownWrites: OwnWriteLedger(),
            ingest: IngestActor(database: database, settings: settings), settings: settings,
            reporter: reporter, ignoredApps: { ignored }, clock: clock, sink: sink, scheduleTimer: inertTimer)
        return Rig408(folder: folder, database: database, board: board, sink: sink, capture: capture, settings: settings, clock: clock, reporter: reporter)
    }

    /// Starts capture with the launch read baselined away: Paused then Active re-reads the baseline (FR-001-19). Without
    /// it the empty board at launch opens the watch of an empty change, which the first copy supersedes and counts
    /// (FR-001-01, FR-001-18 b), a count none of these sequences means to make.
    func start() {
        capture.start()
        settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        settings.set(CaptureMode.active, for: SettingKeys.captureMode)
    }

    /// Ticks the poll.
    func tick(_ times: Int = 1) { for _ in 0..<times { capture.captureNow() } }
    /// Lets the watch of the change in hand run out (FR-001-01) and ticks once, which is when it counts as empty.
    func expire() { clock.advance(by: ClipboardCapture.emptyChangeWatchLimit); tick() }

    /// One persistently empty change whose type list is empty (`clear`), counted when its watch ends.
    func emptyTypesChange() { board.emptyBytes = false; board.clear(); tick(); expire() }
    /// One persistently empty change whose types are listed but whose bytes read back empty.
    func listedEmptyChange(_ s: String = "gated") { board.emptyBytes = true; board.copy([text: Data(s.utf8)]); tick(); expire() }
    /// One change that yields bytes (stored).
    func readableChange(_ s: String) { board.emptyBytes = false; board.copy([text: Data(s.utf8)]); tick() }

    var prm: Int { sink.count(containing: "CAP-PRM-001") }
    var val: Int { sink.count(containing: "CAP-VAL-001") }

    func texts() async throws -> [String] {
        await capture.stop()
        return try await database.pool.read { try String.fetchAll($0, sql: "SELECT plainText FROM item ORDER BY plainText") }
    }
    /// Reports are raised from unstructured tasks: wait for them to reach the sink without a wall-clock sleep.
    func drain() async throws { await quiesceReporter(reporter) }
    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

private let text = "public.utf8-plain-text"

@MainActor
@Suite("TASK-408 worf: listed-but-empty reads count toward CAP-PRM-001")
struct ClipboardEmptyReadWorf408Tests {
    // MARK: threshold and mixed sequences

    @Test("OC-408-W1 three listed-but-empty changes: two raise CAP-VAL-001, the third raises CAP-PRM-001 once")
    func threeListedEmptySuspend() async throws {
        // given two listed-but-empty changes
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        rig.listedEmptyChange(); rig.listedEmptyChange()
        try await rig.drain()
        // then below threshold: no permission notice, one data notice each
        #expect(rig.prm == 0)
        await expectSettled(rig.reporter, rig.val, 2)
        // when the third arrives
        rig.listedEmptyChange()
        try await rig.drain()
        // then CAP-PRM-001 once, and no third CAP-VAL-001 (the suspension replaces it)
        await expectSettled(rig.reporter, rig.prm, 1)
        await expectSettled(rig.reporter, rig.val, 2)
        #expect(try await rig.texts() == [])
    }

    @Test("OC-408-W2 mixed across changes: empty-types, listed-empty, empty-types suspends at three")
    func mixedAcrossChangesSuspend() async throws {
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        // given empty-types, then listed-empty
        rig.emptyTypesChange(); rig.listedEmptyChange()
        try await rig.drain()
        #expect(rig.prm == 0)
        // when an empty-types change follows
        rig.emptyTypesChange()
        try await rig.drain()
        // then the three count together
        await expectSettled(rig.reporter, rig.prm, 1)
    }

    @Test("OC-408-W3 mixed across changes, other order: listed-empty, empty-types, listed-empty suspends at three")
    func mixedOtherOrderSuspend() async throws {
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        rig.listedEmptyChange(); rig.emptyTypesChange()
        try await rig.drain()
        #expect(rig.prm == 0)
        rig.listedEmptyChange()
        try await rig.drain()
        await expectSettled(rig.reporter, rig.prm, 1)
    }

    @Test("OC-408-W4 one change whose reads alternate between empty types and listed-empty is one empty change, not three")
    func alternatingReadsOfOneChangeCountOnce() async throws {
        // given one changeCount whose reads see: no types, types with no bytes, types with no bytes
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        rig.board.clear()
        rig.tick()
        rig.board.emptyBytes = true
        rig.board.fill([text: Data("late".utf8)])
        rig.tick(2)
        rig.expire()
        try await rig.drain()
        // then it counted once when its watch ended (1 types-empty read + 2 snapshot reads), one CAP-VAL-001
        #expect(rig.board.snapshotReads == 2)
        await expectSettled(rig.reporter, rig.val, 1)
        #expect(rig.prm == 0)
        // and two more empty changes (not one) are needed to suspend
        rig.listedEmptyChange()
        try await rig.drain()
        #expect(rig.prm == 0)
        rig.emptyTypesChange()
        try await rig.drain()
        await expectSettled(rig.reporter, rig.prm, 1)
    }

    @Test("OC-408-W5 boundary: a listed-empty change whose watch has not ended is not yet counted")
    func twoReadsDoNotCount() async throws {
        // given two full empty changes and a third still being watched
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        rig.listedEmptyChange(); rig.listedEmptyChange()
        rig.board.emptyBytes = true
        rig.board.copy([text: Data("third".utf8)])
        rig.tick(2)
        try await rig.drain()
        // then no suspension, no more than two data notices
        #expect(rig.prm == 0)
        await expectSettled(rig.reporter, rig.val, 2)
        // when its watch ends
        rig.expire()
        try await rig.drain()
        await expectSettled(rig.reporter, rig.prm, 1)
    }

    // MARK: reset

    @Test("OC-408-W6 a readable change mid-run resets the count: 2 empty, 1 readable, 2 empty never suspends")
    func readableChangeResets() async throws {
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        rig.listedEmptyChange(); rig.listedEmptyChange()
        rig.readableChange("real")
        rig.listedEmptyChange(); rig.listedEmptyChange()
        try await rig.drain()
        // then four empties in all, never three in a row
        #expect(rig.prm == 0)
        #expect(try await rig.texts() == ["real"])
    }

    @Test("OC-408-W7 after the reset exactly three more are needed, mixed kinds included")
    func resetThenThreeMore() async throws {
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        rig.emptyTypesChange(); rig.listedEmptyChange()
        rig.readableChange("real")
        rig.emptyTypesChange(); rig.listedEmptyChange()
        try await rig.drain()
        #expect(rig.prm == 0)
        rig.listedEmptyChange()
        try await rig.drain()
        await expectSettled(rig.reporter, rig.prm, 1)
    }

    @Test("OC-408-W8 a bytes-yielding change whose bytes arrive on the third read still resets the count")
    func lateFillingChangeResets() async throws {
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        rig.listedEmptyChange(); rig.listedEmptyChange()
        // when a change is empty twice and then yields bytes
        rig.board.emptyBytes = true
        rig.board.copy([text: Data("late".utf8)])
        rig.tick(2)
        rig.board.emptyBytes = false
        rig.tick(3)
        // and two further empties follow
        rig.listedEmptyChange(); rig.listedEmptyChange()
        try await rig.drain()
        #expect(rig.prm == 0)
        #expect(try await rig.texts() == ["late"])
    }

    // MARK: exactly once

    @Test("OC-408-W9 while suspended, further listed-empty and empty-types changes never raise CAP-PRM-001 again")
    func exactlyOnceWhileSuspended() async throws {
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        for _ in 1...3 { rig.listedEmptyChange() }
        try await rig.drain()
        await expectSettled(rig.reporter, rig.prm, 1)
        // when many more empty changes of both kinds arrive (each captureNow while suspended is a retry)
        for _ in 1...5 { rig.listedEmptyChange(); rig.emptyTypesChange() }
        rig.tick(20)
        try await rig.drain()
        // then still one notice, and no data notices either (suspended is not a stream of CAP-VAL-001)
        await expectSettled(rig.reporter, rig.prm, 1)
        await expectSettled(rig.reporter, rig.val, 2)
    }

    // MARK: recovery

    @Test("OC-408-W10 a readable change clears the suspension and stores; three new empties raise CAP-PRM-001 a second time")
    func recoveryThenResuspend() async throws {
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        for _ in 1...3 { rig.listedEmptyChange() }
        try await rig.drain()
        await expectSettled(rig.reporter, rig.prm, 1)
        // when access returns
        rig.readableChange("back")
        // then the copy is stored (capture resumed within one tick)
        #expect(try await rig.texts() == ["back"])
        rig.capture.start()
        // and two new empties do not suspend (the counter restarted), the third does (the latch was cleared)
        rig.listedEmptyChange(); rig.emptyTypesChange()
        try await rig.drain()
        await expectSettled(rig.reporter, rig.prm, 1)
        rig.listedEmptyChange()
        try await rig.drain()
        await expectSettled(rig.reporter, rig.prm, 2)
    }

    @Test("OC-408-W11 suspended on listed-empty, a still-gated probe does not resume; first bytes do")
    func gatedProbesDoNotResume() async throws {
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        for _ in 1...3 { rig.listedEmptyChange() }
        // when the board stays gated across many retry ticks of the same change
        rig.tick(30)
        try await rig.drain()
        // then nothing stored and still one notice
        await expectSettled(rig.reporter, rig.prm, 1)
        // and when the bytes land on the same change, the retry picks them up
        rig.board.emptyBytes = false
        rig.tick()
        #expect(try await rig.texts() == ["gated"])
    }

    // MARK: the defer

    @Test("OC-408-W12 empty snapshot does not mark readable on any read: 2 empty, then a change read-empty on every read")
    func emptySnapshotNeverResets() async throws {
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        // Not started: `snapshotReads == 2` pins the exact read count, so the real poll timer (which adds a read whenever
        // `drain()` lets it fire under suite load) must not exist. Every read here is one `captureNow()`.
        rig.emptyTypesChange(); rig.emptyTypesChange()
        // when the third change lists types but every snapshot is empty; while it is watched nothing is counted
        rig.board.emptyBytes = true
        rig.board.copy([text: Data("x".utf8)])
        rig.tick(2)
        try await rig.drain()
        #expect(rig.prm == 0)
        // then the end of its watch is what counts (and reads nothing more)
        rig.expire()
        try await rig.drain()
        await expectSettled(rig.reporter, rig.prm, 1)
        #expect(rig.board.snapshotReads == 2)
    }

    @Test("OC-408-W13 empty snapshot between two empty-types changes does not reset: the run still reaches three")
    func emptySnapshotInTheMiddleDoesNotReset() async throws {
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        rig.emptyTypesChange()
        rig.listedEmptyChange()
        rig.emptyTypesChange()
        try await rig.drain()
        await expectSettled(rig.reporter, rig.prm, 1)
    }

    @Test("OC-408-W14 gates that read nothing (capture paused) leave the empty count untouched")
    func pausedCaptureDoesNotTouchCount() async throws {
        let rig = try await Rig408.make(); defer { rig.cleanUp() }
        rig.start()
        rig.listedEmptyChange(); rig.listedEmptyChange()
        // when capture is paused and a change lands, then resumed
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        rig.listedEmptyChange()
        rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
        try await rig.drain()
        #expect(rig.prm == 0)
        // then the next empty change is the third and suspends
        rig.listedEmptyChange()
        try await rig.drain()
        await expectSettled(rig.reporter, rig.prm, 1)
    }

    @Test("OC-408-W15 characterisation: listed types that a policy rejects are readable type data and reset the count")
    func policySkipResetsCount() async throws {
        // given two empties, then an ignored-app copy (types listed, bytes never requested), then two empties
        let rig = try await Rig408.make(ignored: ["com.example.writer"]); defer { rig.cleanUp() }
        rig.start()
        rig.listedEmptyChange(); rig.listedEmptyChange()
        rig.readableChange("ignored")
        rig.listedEmptyChange(); rig.listedEmptyChange()
        try await rig.drain()
        // then the skip counted as readable: no suspension (pins current behaviour, see report)
        #expect(rig.prm == 0)
        #expect(try await rig.texts() == [])
    }
}
