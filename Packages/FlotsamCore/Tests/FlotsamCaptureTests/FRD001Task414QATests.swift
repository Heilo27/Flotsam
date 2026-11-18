import Foundation
import Testing
import GRDB
import FlotsamBase
import FlotsamPayload
@testable import FlotsamStorage
@testable import FlotsamCapture

// Blind QA of TASK-414 (FRD-001 FR-001-18, FR-001-22). Judged against docs/frd/FRD-001-Capture.md and
// .claude/oracle/frd-001-contract.json, not against the implementation's own tests.

@MainActor
private final class SwitchableAccess: PasteboardAccessPort {
    var isReadAllowed: Bool
    init(_ allowed: Bool) { isReadAllowed = allowed }
}

@MainActor
private struct QARig {
    let database: FlotsamDatabase
    let presenter: FRD001RecordingPresenter
    let sink: RecordingSink
    let clock: ManualClock
    let reporter: ErrorReporter
    let pasteboard: ContractPasteboard
    let capture: ClipboardCapture

    func settle() async { await quiesceReporter(reporter) }

    func until(seconds: Double = 5, _ condition: () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return (try? await condition()) == true
    }

    func texts() async throws -> [String] {
        try await database.pool.read { try String.fetchAll($0, sql: "SELECT plainText FROM item ORDER BY rowid") }
    }

    /// One change with no type data, polled the three times FR-001-01 / FR-001-18 b count as one empty change.
    func emptyChange() async {
        pasteboard.copy([PasteboardRepresentation]())
        for _ in 0..<3 { capture.captureNow() }
        await settle()
    }

    var codes: [ErrorCode] { presenter.latestNotices.map(\.code) }
}

@MainActor
private func withQARig(
    access: any PasteboardAccessPort, prefill: String? = nil, timers: FakeTimers? = nil, _ body: (QARig) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-414qa-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data")).get()
    let presenter = FRD001RecordingPresenter()
    let sink = RecordingSink()
    let clock = ManualClock()
    let reporter = ErrorReporter(presenter: presenter, clock: clock, sink: sink)
    let settings = SettingsStore(store: ContractKV())
    let pasteboard = ContractPasteboard()
    if let prefill { pasteboard.copyText(prefill) }
    let capture = ClipboardCapture(
        pasteboard: pasteboard, sourceApps: ContractSourceApps(frontmost: ContractRig.writerApp), ownWrites: OwnWriteLedger(),
        ingest: IngestActor(database: database, settings: settings), settings: settings, reporter: reporter,
        ignoredApps: { [] }, access: access, clock: clock, sink: sink,
        scheduleTimer: timers?.schedule ?? ClipboardCapture.systemTimer)
    capture.start()
    let rig = QARig(database: database, presenter: presenter, sink: sink, clock: clock, reporter: reporter, pasteboard: pasteboard, capture: capture)
    do { try await body(rig) } catch {
        await capture.stop()
        throw error
    }
    await capture.stop()
}

// MARK: FR-001-22 mapping (IngestWorker.captureFailure)

@MainActor
@Suite("TASK-414 QA: FR-001-22 CAP-IO-001 mapping")
struct Task414CaptureFailureMappingTests {

    @Test("OC-1110: exactly STO-DB-001 and STO-IO-001 become CAP-IO-001; every other code passes through unchanged")
    func mappingIsExactlyTwoCodes() {
        // given every code in the taxonomy; when it fails a capture write; then only the two disk/database codes change.
        var mapped: [String] = []
        for code in ErrorCode.allCases {
            let input = FlotsamError(code, "qa")
            let out = IngestWorker.captureFailure(input)
            if out.code != code { mapped.append("\(code.rawValue)->\(out.code.rawValue)") }
            if code != .stoDb001 && code != .stoIo001 { #expect(out == input, "\(code.rawValue) must pass through untouched") }
        }
        #expect(mapped.sorted() == ["STO-DB-001->CAP-IO-001", "STO-IO-001->CAP-IO-001"])
    }

    @Test("OC-1110: the mapped error keeps the underlying cause and the context")
    func mappingKeepsCause() {
        let cause = UnderlyingErrorInfo(domain: "GRDB.DatabaseError", code: 8)
        for source in [ErrorCode.stoDb001, .stoIo001] {
            let out = IngestWorker.captureFailure(FlotsamError(source, "qa", context: [.byteSize: .bytes(42)], underlying: cause))
            #expect(out.code == .capIo001)
            #expect(out.underlying == cause)
            // The original STO code is kept in the context (TASK-417, FR-001-22) alongside the caller's own fields.
            #expect(out.context == [.byteSize: .bytes(42), .code: .code(source)])
            #expect(out.severity == .error)
        }
    }

    @Test("TASK-417 FR-001-22: with no underlying error (DiskGuard, BlobStore) the CAP-IO-001 record still names the STO code that was refused")
    func nilUnderlyingKeepsStoCode() async {
        for source in [ErrorCode.stoDb001, .stoIo001] {
            let mapped = IngestWorker.captureFailure(FlotsamError(source, "qa refusal", underlying: nil))
            #expect(mapped.code == .capIo001)
            #expect(mapped.underlying == nil)
            #expect(mapped.context[.code] == .code(source))

            let sink = RecordingSink()
            let reporter = ErrorReporter(presenter: FRD001RecordingPresenter(), sink: sink)
            await reporter.report(mapped, origin: .background)
            let records = sink.records.filter { $0.headline.hasPrefix("CAP-IO-001 ") }
            #expect(records.count == 1)
            #expect(records.first?.publicContext.contains("code=\(source.rawValue)") == true, "record: \(String(describing: records.first))")
        }
    }

    @Test("OC-1092 end to end: a refused write is mapped once (one CAP-IO-001 Notice, no STO-* Notice), and the next copy is stored")
    func refusedWriteEndToEnd() async throws {
        try await withQARig(access: SwitchableAccess(true)) { rig in
            try await rig.database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA query_only = ON") }
            let failed = uid("fail")
            rig.pasteboard.copyText(failed)
            rig.capture.captureNow()
            #expect(await rig.until { !rig.presenter.latestNotices.isEmpty })
            await rig.settle()
            #expect(rig.codes == [.capIo001])
            // The STO code must not surface as a record of its own. It is named inside the one CAP-IO-001 record's context
            // (TASK-417), so the check is on the headline, not on `code=` anywhere (which `logged(_:)` also matches).
            #expect(!rig.sink.records.contains { $0.headline.hasPrefix("STO-DB-001 ") || $0.headline.hasPrefix("STO-IO-001 ") },
                    "the STO code must not also surface")
            let capIo = rig.sink.records.filter { $0.headline.hasPrefix("CAP-IO-001 ") }
            #expect(capIo.count == 1 && capIo[0].publicContext.contains("code=STO-"), "the one CAP-IO-001 record names the STO cause: \(capIo)")
            let stored = try await rig.texts()
            #expect(stored == [])

            try await rig.database.pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA query_only = OFF") }
            let ok = uid("ok")
            rig.pasteboard.copyText(ok)
            rig.capture.captureNow()
            #expect(await rig.until { try await rig.texts() == [ok] })
        }
    }
}

// MARK: FR-001-18 launch check, resume, duplicates

@MainActor
@Suite("TASK-414 QA: FR-001-18 suspension, resume, duplicates")
struct Task414SuspensionTests {

    @Test("OC-1084: blocked at launch then many empty changes raise CAP-PRM-001 exactly once, one Notice")
    func noDuplicateRaise() async throws {
        try await withQARig(access: SwitchableAccess(false)) { rig in
            await rig.settle()
            for _ in 0..<5 { await rig.emptyChange() }
            #expect(rig.sink.logged(.capPrm001).count == 1)
            #expect(rig.codes == [.capPrm001])
        }
    }

    @Test("OC-1084 boundary: access Allow at launch, two empty changes: no CAP-PRM-001 (the launch check does not lower the three-change rule)")
    func allowedThenTwoEmpty() async throws {
        try await withQARig(access: SwitchableAccess(true)) { rig in
            await rig.emptyChange()
            await rig.emptyChange()
            #expect(rig.sink.logged(.capPrm001).isEmpty)
            #expect(rig.codes.isEmpty)
        }
    }

    /// Runs on the timer seam (ADR-0011) and the manual clock: the 60 s probe is driven by firing the one scheduled
    /// source by hand, so neither a real 0.5 s tick nor a sleep decides the outcome (TASK-447: a real-timer wait of
    /// 1.2 s / 3 s lost the race under full-suite load).
    @Test("OC-1083 (launch variant): blocked at launch, text becomes readable without a changeCount bump, 60 s probe stores it and clears the Notice")
    func launchBlockedProbeResumes() async throws {
        let timers = FakeTimers()
        try await withQARig(access: SwitchableAccess(false), timers: timers) { rig in
            await rig.settle()
            #expect(rig.codes == [.capPrm001])
            await rig.emptyChange()  // finish the launch change's three reads so the reveal below is a hidden, not a re-read, change
            let source = try #require(timers.live.first, "capture schedules its poll source")
            let v = uid("probe")
            rig.pasteboard.reveal([PasteboardRepresentation(uti: PasteboardTypes.plainText, data: Data(v.utf8))])
            rig.clock.advance(by: 59)
            let typeQueriesBefore = rig.pasteboard.typeQueries
            source.fire()
            // A tick at 59 s reads `changeCount` only: the probe has not run, so no type or byte read happened.
            #expect(rig.pasteboard.typeQueries == typeQueriesBefore, "59 s: the probe has not run")
            await rig.settle()
            let stored = try await rig.texts()
            #expect(stored == [], "59 s: the probe has not run")
            #expect(rig.codes == [.capPrm001], "59 s: the Notice stays")
            rig.clock.advance(by: 1)
            source.fire()
            #expect(await rig.until(seconds: 10) { try await rig.texts() == [v] })
            #expect(await rig.until(seconds: 10) { rig.codes.isEmpty })
            await rig.settle()
            #expect(rig.codes.isEmpty)
        }
    }

    @Test("FR-001-18: suspend, resume, suspend again within 60 s: the second CAP-PRM-001 is shown (a late clear must not erase it)")
    func resumeThenSuspendAgain() async throws {
        try await withQARig(access: SwitchableAccess(false)) { rig in
            await rig.settle()
            let r = uid("R")
            rig.pasteboard.copyText(r)
            rig.capture.captureNow()
            #expect(await rig.until { rig.codes.isEmpty && rig.presenter.noticeLists.count >= 2 })
            // No clock advance: the resume cleared the Notice and with it the 60 s throttle (FR-000-08), so a re-suspend
            // inside the window shows the Notice again (FR-001-18).
            for _ in 0..<3 { await rig.emptyChange() }
            // Presence is awaited, not slept for; the strict assertions then run after a quiesce, so a late clear
            // arriving after the Notice appeared would still fail them.
            #expect(await rig.until { rig.sink.logged(.capPrm001).count == 2 && rig.codes == [.capPrm001] })
            await rig.settle()
            #expect(rig.sink.logged(.capPrm001).count == 2)
            #expect(rig.codes == [.capPrm001], "lists: \(rig.presenter.noticeLists.map { $0.map(\.code.rawValue) })")
            #expect(await rig.until { try await rig.texts() == [r] })
            let stored = try await rig.texts()
            #expect(stored == [r])
        }
    }

    @Test("FR-001-18: resume clears only CAP-PRM-001; another Notice survives")
    func resumeClearsOnlyPrm() async throws {
        try await withQARig(access: SwitchableAccess(false)) { rig in
            await rig.settle()
            await rig.reporter.report(FlotsamError(.capIo001, "qa other notice"), origin: .background)
            await rig.settle()
            #expect(Set(rig.codes) == [.capPrm001, .capIo001])
            let r = uid("R")
            rig.pasteboard.copyText(r)
            rig.capture.captureNow()
            #expect(await rig.until { !rig.codes.contains(.capPrm001) })
            #expect(rig.codes == [.capIo001])
        }
    }

    @Test("FR-001-18: a readable read that is not a resume clears nothing (not suspended: every Notice stays, CAP-PRM-001 included)")
    func readableWithoutTransitionClearsNothing() async throws {
        try await withQARig(access: SwitchableAccess(true)) { rig in
            await rig.reporter.report(FlotsamError(.capIo001, "qa other notice"), origin: .background)
            await rig.reporter.report(FlotsamError(.capPrm001, "qa injected", context: [.permission: .permission(.pasteboard)]), origin: .background)
            await rig.settle()
            #expect(Set(rig.codes) == [.capIo001, .capPrm001])
            for n in 0..<3 {
                let text = uid("N\(n)")
                rig.pasteboard.copyText(text)
                rig.capture.captureNow()
                #expect(await rig.until { try await rig.texts().contains(text) })
            }
            await rig.settle()
            let stored = try await rig.texts()
            #expect(stored.count == 3)
            #expect(Set(rig.codes) == [.capIo001, .capPrm001], "no transition happened, so nothing may clear")
        }
    }
}

// MARK: Source identity

@Suite("TASK-414 QA: another-device source name")
struct Task414SourceNameTests {
    @Test("FR-001-14: the stored bucket name is the catalogue literal 'Another device'")
    func anotherDeviceLiteral() {
        #expect(SourceApp.anotherDeviceName == "Another device")
        #expect(FlotsamStrings.text(forKey: "ui.source.remoteDevice") == "Another device")
    }
}
