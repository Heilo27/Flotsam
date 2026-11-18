import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShelf

/// TASK-412 QA additions (Worf). Pins what the implementer's suite left open: the whole line as the user reads it,
/// for every trigger (FR-006-18, AC-006-19), nothing redacted-only riding along, and repeated reveals not coalescing.
@Suite struct ShelfRevealAnnouncementQATests {
    private final class Capture: LogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        private var written: [LogRecord] = []
        func write(_ record: LogRecord) { lock.withLock { items.append("log"); written.append(record) } }
        func hid() { lock.withLock { items.append("hide") } }
        var order: [String] { lock.withLock { items } }
        var records: [LogRecord] { lock.withLock { written } }
    }

    private static let literalTriggers = ["drag", "hover", "hotkey", "menuItem", "menuBarIconDrag"]

    // OC-006-18a: given each trigger, when announced, then the readable line is exactly the spec line.
    @Test @MainActor func publicLineIsExactlyTheSpecLineForEveryTrigger() {
        let all = ShelfTrigger.allCases
        #expect(all.count == 5)
        #expect(all.map(\.rawValue) == Self.literalTriggers)
        for (trigger, literal) in zip(all, Self.literalTriggers) {
            let sink = Capture()
            ShelfRevealAnnouncement.announce(trigger, hideLibrary: nil, sink: sink)
            #expect(sink.records.count == 1, "\(literal)")
            #expect(sink.records.first?.publicText == "shelf.reveal outcome=revealed trigger=\(literal)", "\(literal)")
        }
    }

    // OC-006-18b: given any trigger, then level is info, category shelf, and no redacted text (private context,
    // message, cause) is attached: the line carries the trigger type and nothing else (FR-006-18, AC-006-19).
    @Test @MainActor func lineCarriesNothingBeyondTheTriggerForEveryTrigger() {
        for trigger in ShelfTrigger.allCases {
            let sink = Capture()
            ShelfRevealAnnouncement.announce(trigger, hideLibrary: nil, sink: sink)
            guard let record = sink.records.first else { Issue.record("no record for \(trigger)"); continue }
            #expect(record.level == .info, "\(trigger)")
            #expect(record.category == .shelf, "\(trigger)")
            #expect(record.privateText.trimmingCharacters(in: .whitespaces).isEmpty, "\(trigger)")
            #expect(record.message == nil, "\(trigger)")
            #expect(record.cause == nil, "\(trigger)")
        }
    }

    // OC-006-04a: given two reveals in a row, then two hides and two lines in strict hide,log,hide,log order
    // (no coalescing, no skipped hide on the second reveal).
    @Test @MainActor func twoRevealsHideAndLogTwiceInOrder() {
        let sink = Capture()
        ShelfRevealAnnouncement.announce(.hotkey, hideLibrary: { sink.hid() }, sink: sink)
        ShelfRevealAnnouncement.announce(.menuItem, hideLibrary: { sink.hid() }, sink: sink)
        #expect(sink.order == ["hide", "log", "hide", "log"])
        #expect(sink.records.map(\.publicContext) == ["outcome=revealed trigger=hotkey", "outcome=revealed trigger=menuItem"])
    }

    // OC-006-04b: given the hide hook, when it runs, then no reveal line exists yet (hide cannot be skipped by a
    // log-first ordering) and the log is not written by the hook path.
    @Test @MainActor func noRevealLineExistsWhenTheHideHookRuns() {
        let sink = Capture()
        var linesSeenByHook = -1
        ShelfRevealAnnouncement.announce(.drag, hideLibrary: { linesSeenByHook = sink.records.count }, sink: sink)
        #expect(linesSeenByHook == 0)
        #expect(sink.records.count == 1)
    }
}
