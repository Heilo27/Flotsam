import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf

/// OC-6082 / FR-006-11 (QA, TASK-439): the full input matrix of `ShelfDragEnd.resolve`.
/// Inputs are accepted x cards (empty / one / many). Expected values are literals.
@Suite struct ShelfDragEndMatrixTests {
    private let one = [shelfID(7)]
    private let three = [shelfID(3), shelfID(1), shelfID(2)]

    // MARK: accepted -> counts exactly the dragged cards, in order

    @Test func oc6082_acceptedCarriesEveryCardInOrder() {
        // given an accepted drop of 3 cards, when it resolves, then all 3 are counted in drag order (paste count +1 each).
        let end = ShelfDragEnd.resolve(accepted: true, cards: three)
        #expect(end == .accepted(cards: [shelfID(3), shelfID(1), shelfID(2)]))
    }

    @Test func oc6082_acceptedSingleCardCountsOneNotMore() {
        let end = ShelfDragEnd.resolve(accepted: true, cards: one)
        guard case .accepted(let counted) = end else { Issue.record("expected accepted, got \(end)"); return }
        #expect(counted.count == 1)
        #expect(counted.first == shelfID(7))
    }

    // MARK: not accepted -> never carries cards, so no paste is recorded

    @Test func oc6082_notAcceptedIsUserCancelWithNoError() {
        // AppKit always begins a session that starts, so an ended session with no operation is a cancel, not an abort.
        #expect(ShelfDragEnd.resolve(accepted: false, cards: three) == .userCancelled)
        #expect(ShelfDragEnd.resolve(accepted: false, cards: one) == .userCancelled)
    }

    @Test func oc6082_cancelNeverResolvesToAccepted() {
        // pasteCount unchanged: the only case that carries cards to count is .accepted.
        let end = ShelfDragEnd.resolve(accepted: false, cards: three)
        if case .accepted = end { Issue.record("not-accepted resolved to accepted: \(end)") }
    }

    // MARK: no cards -> nothing, both accepted values (empty boundary)

    @Test(arguments: [true, false])
    func noCardsMeansNothingToCountOrReport(accepted: Bool) {
        #expect(ShelfDragEnd.resolve(accepted: accepted, cards: []) == .none)
    }

    // MARK: stability

    @Test func resolveIsPureSameInputsSameResult() {
        let first = ShelfDragEnd.resolve(accepted: false, cards: three)
        let second = ShelfDragEnd.resolve(accepted: false, cards: three)
        #expect(first == second)
    }

    @Test func eachResultCaseIsDistinct() {
        let all: [ShelfDragEnd] = [.accepted(cards: one), .userCancelled, .none]
        for (i, a) in all.enumerated() { for (j, b) in all.enumerated() where i != j { #expect(a != b) } }
    }
}
