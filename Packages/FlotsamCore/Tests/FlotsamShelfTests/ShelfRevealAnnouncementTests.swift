import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShelf

/// TASK-412: the reveal log record (FR-006-18) and the Shelf hiding an open Library (FR-006-04, one Flotsam panel at a
/// time). Both live in `ShelfRevealAnnouncement`, the part of `ShelfPanelController.reveal` the app has no test target
/// to reach.
@Suite struct ShelfRevealAnnouncementTests {
    /// Records the order of events across the hide callback and the log write, so a test can see which came first.
    private final class Journal: LogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        private var written: [LogRecord] = []
        func write(_ record: LogRecord) { lock.withLock { entries.append("log"); written.append(record) } }
        func libraryHidden() { lock.withLock { entries.append("hideLibrary") } }
        var order: [String] { lock.withLock { entries } }
        var records: [LogRecord] { lock.withLock { written } }
    }

    @Test @MainActor func revealWritesOneInfoLineWithCategoryOutcomeAndTrigger() {
        let journal = Journal()
        ShelfRevealAnnouncement.announce(.hotkey, hideLibrary: nil, sink: journal)
        #expect(journal.records.count == 1)
        guard let record = journal.records.first else { return }
        #expect(record.category == .shelf)
        #expect(record.level == .info)
        #expect(record.headline == "shelf.reveal")
        #expect(record.publicContext == "outcome=revealed trigger=hotkey")
        #expect(record.privateContext.isEmpty)
        #expect(record.message == nil)
    }

    @Test @MainActor func everyTriggerTypeIsNamedInItsLine() {
        for trigger in ShelfTrigger.allCases {
            let journal = Journal()
            ShelfRevealAnnouncement.announce(trigger, hideLibrary: nil, sink: journal)
            #expect(journal.records.map(\.publicContext) == ["outcome=revealed trigger=\(trigger.rawValue)"], "\(trigger)")
        }
    }

    @Test @MainActor func revealRequestsExactlyOneLibraryHide() {
        let journal = Journal()
        ShelfRevealAnnouncement.announce(.menuItem, hideLibrary: { journal.libraryHidden() }, sink: journal)
        #expect(journal.order.filter { $0 == "hideLibrary" }.count == 1)
    }

    @Test @MainActor func libraryIsHiddenBeforeTheRevealIsLogged() {
        let journal = Journal()
        ShelfRevealAnnouncement.announce(.hover, hideLibrary: { journal.libraryHidden() }, sink: journal)
        #expect(journal.order == ["hideLibrary", "log"])
    }

    @Test @MainActor func everyTriggerHidesTheLibrary() {
        for trigger in ShelfTrigger.allCases {
            let journal = Journal()
            ShelfRevealAnnouncement.announce(trigger, hideLibrary: { journal.libraryHidden() }, sink: journal)
            #expect(journal.order == ["hideLibrary", "log"], "\(trigger)")
        }
    }

    @Test @MainActor func aShelfWithNoLibraryHookStillLogsTheReveal() {
        let journal = Journal()
        ShelfRevealAnnouncement.announce(.drag, hideLibrary: nil, sink: journal)
        #expect(journal.order == ["log"])
    }
}
