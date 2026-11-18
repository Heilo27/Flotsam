import Foundation
import Testing
@testable import FlotsamBase

// FRD-006 FR-006-18: the Shelf's three log lines carry a count, a trigger type or an outcome code and nothing else.

@Suite struct ShelfLogEventTests {
    @Test("OC-6117 a reveal line carries the trigger type as a public enum raw value", arguments: ShelfTrigger.allCases)
    func revealCarriesTrigger(trigger: ShelfTrigger) {
        let event = LogEvent.shelf(.reveal, outcome: .revealed, detail: .trigger(trigger))
        #expect(event.name == "shelf.reveal")
        #expect(event.category.rawValue == "shelf")
        let rendered = FlotsamLog.render(event.fields)
        #expect(rendered.publicPart == "outcome=revealed trigger=\(trigger.rawValue)")
        #expect(rendered.privatePart == "")
    }

    @Test("OC-6117 a drag-out line carries the item count")
    func dragOutCarriesCount() {
        let event = LogEvent.shelf(.dragOut, outcome: .draggedOut, detail: .count(3))
        let rendered = FlotsamLog.render(event.fields)
        #expect(event.name == "shelf.dragOut")
        #expect(rendered.publicPart == "count=3 outcome=draggedOut")
        #expect(rendered.privatePart == "")
    }

    @Test("OC-6118 a drop line carries the outcome and, when not fully stored, the error code")
    func dropCarriesOutcomeAndCode() {
        let partial = LogEvent.shelf(.dropIn, outcome: .stored, detail: .code(.shfIo001))
        #expect(partial.name == "shelf.dropIn")
        #expect(FlotsamLog.render(partial.fields).publicPart == "code=SHF-IO-001 outcome=stored")
        let plain = LogEvent.shelf(.dropIn, outcome: .droppedIn)
        #expect(FlotsamLog.render(plain.fields).publicPart == "outcome=droppedIn")
    }
}
