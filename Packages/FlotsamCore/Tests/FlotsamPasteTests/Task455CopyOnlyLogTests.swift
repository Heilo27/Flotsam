import Foundation
import Testing
import FlotsamBase
import FlotsamStorage
@testable import FlotsamPaste

// TASK-455: ⇧Return (copy-only, ADR-0005) copies; it does not paste. Its log lines must say so (FR-000-11), or a log
// reader counts copies as paste-backs.

private final class CopySink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { all.append(record) } }
    var texts: [String] { lock.withLock { all.map(\.publicText) } }
}

@MainActor
@Suite struct Task455CopyOnlyLogTests {
    static let target = FrontmostApp(bundleId: "com.apple.Notes", processId: 42)
    let itemId = UUID()

    private func rig(_ content: FlotsamResult<ItemContent>, trusted: Bool = true) -> (PasteService, FakePasteboard, FakeHost, CopySink) {
        let pasteboard = FakePasteboard()
        let sink = CopySink()
        let service = PasteService(
            store: FakeStore(content), pasteboard: pasteboard, files: FakeFiles(existing: []),
            frontmost: FakeFrontmost(target: Self.target, pollsUntilTarget: 0),
            accessibility: FakePermission(isAccessibilityTrusted: trusted), keys: FakeKeys(), clock: RecordingClock(),
            ownWrites: OwnWriteLedger(), sink: sink)
        return (service, pasteboard, FakeHost(), sink)
    }

    private var content: ItemContent { ItemContent(kind: .text, plainText: "hello", representations: [], members: []) }

    @Test func copyOnlyLogsPasteCopyNotPasteBack() async throws {
        let (service, _, host, sink) = rig(.success(content))
        let outcome = try await service.paste(itemId: itemId, mode: .copyOnly, target: Self.target, host: host).get()
        #expect(outcome == .copied)
        #expect(sink.texts == ["paste.copy outcome=started", "paste.copy outcome=succeeded"])
    }

    @Test func copyOnlyWithAccessibilityDeniedIsStillACopySuccessNotDenied() async throws {
        let (service, _, host, sink) = rig(.success(content), trusted: false)
        _ = try await service.paste(itemId: itemId, mode: .copyOnly, target: Self.target, host: host).get()
        #expect(sink.texts == ["paste.copy outcome=started", "paste.copy outcome=succeeded"])
    }

    @Test func copyOnlyFailureLogsPasteCopyFailed() async {
        let (service, pasteboard, host, sink) = rig(.success(content))
        pasteboard.failWith = FlotsamError(.libOs001, "write refused")
        _ = await service.paste(itemId: itemId, mode: .copyOnly, target: Self.target, host: host)
        #expect(sink.texts == ["paste.copy outcome=started", "paste.copy outcome=failed"])
    }
}
