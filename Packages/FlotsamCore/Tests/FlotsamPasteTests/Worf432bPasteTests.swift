import Foundation
import Testing
import FlotsamBase
import FlotsamStorage
@testable import FlotsamPaste

// TASK-432 blind QA, FR-000-11 "paste-back": started, then exactly one closing outcome; never the item or content.

private final class PasteSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [LogRecord] = []
    var records: [LogRecord] { lock.withLock { all } }
    func write(_ record: LogRecord) { lock.withLock { all.append(record) } }
    var texts: [String] { records.map(\.publicText) }
    var everything: String { records.map { "\($0.publicText) \($0.privateText)" }.joined(separator: "\n") }
}

@MainActor
@Suite struct Worf432bPasteTests {
    static let target = FrontmostApp(bundleId: "com.apple.Notes", processId: 42)
    let itemId = UUID()

    private struct Rig { let service: PasteService; let pasteboard: FakePasteboard; let host: FakeHost; let sink: PasteSink }

    private func rig(_ content: FlotsamResult<ItemContent>, trusted: Bool = true) -> Rig {
        let pasteboard = FakePasteboard()
        let sink = PasteSink()
        let service = PasteService(
            store: FakeStore(content), pasteboard: pasteboard, files: FakeFiles(existing: []),
            frontmost: FakeFrontmost(target: Self.target, pollsUntilTarget: 0),
            accessibility: FakePermission(isAccessibilityTrusted: trusted), keys: FakeKeys(), clock: RecordingClock(),
            ownWrites: OwnWriteLedger(), sink: sink)
        return Rig(service: service, pasteboard: pasteboard, host: FakeHost(), sink: sink)
    }

    private var secretContent: ItemContent {
        ItemContent(kind: .text, plainText: "SECRETPASTEzqx-77", representations: [], members: [])
    }

    private func expansion() -> PasteExpansion {
        let board = FakePasteboard()
        let ledger = OwnWriteLedger()
        let clock = RecordingClock()
        return PasteExpansion(
            pasteboard: board, files: FakeFiles(existing: []), codec: FakeRichTextCodec(),
            preserver: ClipboardPreserver(pasteboard: board, ownWrites: ledger, clock: clock), ownWrites: ledger, clock: clock)
    }

    /// OC-432-40. Given a normal paste, then the log is exactly started, succeeded (two lines, in order, .info). Red if
    /// either callsite is dropped, duplicated, or the outcome mapped wrongly.
    @Test func oc43240_successfulPasteLogsStartedThenSucceeded() async throws {
        let r = rig(.success(secretContent))
        let outcome = try await r.service.paste(itemId: itemId, mode: .paste, target: Self.target, host: r.host).get()
        #expect(outcome == .pasted)
        #expect(r.sink.texts == ["paste.back outcome=started", "paste.back outcome=succeeded"])
        #expect(r.sink.records.allSatisfy { $0.level == .info })
    }

    /// OC-432-41. Given Accessibility is denied (copy instead of paste), then started then `denied`, not `succeeded`.
    @Test func oc43241_accessibilityDeniedLogsDenied() async throws {
        let r = rig(.success(secretContent), trusted: false)
        let outcome = try await r.service.paste(itemId: itemId, mode: .paste, target: Self.target, host: r.host).get()
        #expect(outcome == .copiedAccessibilityDenied)
        #expect(r.sink.texts == ["paste.back outcome=started", "paste.back outcome=denied"])
    }

    /// OC-432-42. Given a pasteboard write failure, then started then `failed`; the failure is still returned.
    @Test func oc43242_failureLogsFailed() async {
        let r = rig(.success(secretContent))
        r.pasteboard.failWith = FlotsamError(.libOs001, "write refused")
        let result = await r.service.paste(itemId: itemId, mode: .paste, target: Self.target, host: r.host)
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == .libOs001)
        #expect(r.sink.texts == ["paste.back outcome=started", "paste.back outcome=failed"])
    }

    /// OC-432-43. Given the item cannot be loaded (error before any write), then the pair is still logged: started,
    /// failed. Red if an early return skips the closing line.
    @Test func oc43243_loadFailureStillClosesTheStartedLine() async {
        let r = rig(.failure(FlotsamError(.stoDb004, "locked")))
        _ = await r.service.paste(itemId: itemId, mode: .paste, target: Self.target, host: r.host)
        #expect(r.sink.texts == ["paste.back outcome=started", "paste.back outcome=failed"])
    }

    /// OC-432-44. The expanded (trigger / item-hotkey) path logs the same pair, success and failure.
    @Test func oc43244_expandedPasteLogsStartedThenOutcome() async throws {
        let ok = rig(.success(secretContent))
        _ = try await ok.service.pasteExpanded(itemId: itemId, target: Self.target, expansion: expansion()).get()
        #expect(ok.sink.texts == ["paste.back outcome=started", "paste.back outcome=succeeded"])

        let bad = rig(.failure(FlotsamError(.stoDb004, "locked")))
        _ = await bad.service.pasteExpanded(itemId: itemId, target: Self.target, expansion: expansion())
        #expect(bad.sink.texts == ["paste.back outcome=started", "paste.back outcome=failed"])
    }

    /// OC-432-45 (privacy). Given an item whose text is distinctive and an item id, when pasted, then no log line
    /// (public or private) contains the text or the item id. Red if a callsite adds the content or the id.
    @Test func oc43245_noContentOrItemIdInAnyPasteLine() async throws {
        let r = rig(.success(secretContent))
        _ = try await r.service.paste(itemId: itemId, mode: .paste, target: Self.target, host: r.host).get()
        #expect(r.sink.records.count == 2)
        #expect(!r.sink.everything.contains("SECRETPASTE"))
        #expect(!r.sink.everything.contains(itemId.uuidString))
        #expect(!r.sink.everything.contains("com.apple.Notes"))
    }
}
