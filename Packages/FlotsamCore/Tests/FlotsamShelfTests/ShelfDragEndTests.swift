import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf

/// OC-6082 / FR-006-11: a system-aborted drag-out reports SHF-OS-001 and changes nothing; a user cancel shows nothing.
@Suite struct ShelfDragEndTests {
    private let cards = [shelfID(1), shelfID(2)]

    @Test func oc6082_aSessionThatEndsWithNoOperationAndNeverBeganWasAbortedAndReportsShfOs001() {
        let end = ShelfDragEnd.resolve(accepted: false, sessionBegan: false, cards: cards)
        guard case .aborted(let error) = end else {
            Issue.record("expected .aborted, got \(end)")
            return
        }
        #expect(error.code == .shfOs001)
        #expect(error.severity == .error)
    }

    @Test func aDragCancelledByTheUserAfterItBeganReportsNothing() {
        #expect(ShelfDragEnd.resolve(accepted: false, sessionBegan: true, cards: cards) == .userCancelled)
    }

    @Test func anAcceptedDragCountsEachCardOnceAndIsNeverAnError() {
        #expect(ShelfDragEnd.resolve(accepted: true, sessionBegan: true, cards: cards) == .accepted(cards: cards))
    }

    @Test func anAbortCarriesNoCardsToCountSoPasteCountIsUnchanged() {
        let end = ShelfDragEnd.resolve(accepted: false, sessionBegan: false, cards: cards)
        if case .accepted = end { Issue.record("an abort must not be accounted as accepted") }
    }

    @Test func aSessionWithNothingDraggedHasNothingToReport() {
        #expect(ShelfDragEnd.resolve(accepted: false, sessionBegan: false, cards: []) == .none)
        #expect(ShelfDragEnd.resolve(accepted: true, sessionBegan: true, cards: []) == .none)
    }
}
