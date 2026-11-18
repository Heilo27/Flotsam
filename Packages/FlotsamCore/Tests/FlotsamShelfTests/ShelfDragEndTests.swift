import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf

/// OC-6082 / FR-006-11: a drag ended with no operation is a user cancel and shows nothing; a drag the OS cannot start or
/// supply reports SHF-OS-001 before or while it runs (`ShelfDragStart`), never at its end.
@Suite struct ShelfDragEndTests {
    private let cards = [shelfID(1), shelfID(2)]

    @Test func aDragEndedWithNoOperationIsAUserCancelAndReportsNothing() {
        #expect(ShelfDragEnd.resolve(accepted: false, cards: cards) == .userCancelled)
    }

    @Test func anAcceptedDragCountsEachCardOnceAndIsNeverAnError() {
        #expect(ShelfDragEnd.resolve(accepted: true, cards: cards) == .accepted(cards: cards))
    }

    @Test func aCancelCarriesNoCardsToCountSoPasteCountIsUnchanged() {
        let end = ShelfDragEnd.resolve(accepted: false, cards: cards)
        if case .accepted = end { Issue.record("a cancel must not be accounted as accepted") }
    }

    @Test func aSessionWithNothingDraggedHasNothingToReport() {
        #expect(ShelfDragEnd.resolve(accepted: false, cards: []) == .none)
        #expect(ShelfDragEnd.resolve(accepted: true, cards: []) == .none)
    }
}
