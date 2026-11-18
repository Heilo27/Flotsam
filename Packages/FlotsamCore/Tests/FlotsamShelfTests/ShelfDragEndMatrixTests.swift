import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf

/// OC-6082 / FR-006-11 (QA, TASK-439): the full input matrix of `ShelfDragEnd.resolve`.
/// Inputs are accepted x sessionBegan x cards (empty / one / many). Expected values are literals.
@Suite struct ShelfDragEndMatrixTests {
    private let one = [shelfID(7)]
    private let three = [shelfID(3), shelfID(1), shelfID(2)]

    // MARK: accepted -> counts exactly the dragged cards, in order, whatever the begin flag says

    @Test func oc6082_acceptedWithBeganCarriesEveryCardInOrder() {
        // given an accepted drop of 3 cards, when it resolves, then all 3 are counted in drag order (paste count +1 each).
        let end = ShelfDragEnd.resolve(accepted: true, sessionBegan: true, cards: three)
        #expect(end == .accepted(cards: [shelfID(3), shelfID(1), shelfID(2)]))
    }

    @Test func oc6082_acceptedWithoutBeganIsStillAccepted() {
        // given an accepted operation but a missed begin callback, when it resolves, then it is a paste, not an abort.
        let end = ShelfDragEnd.resolve(accepted: true, sessionBegan: false, cards: one)
        #expect(end == .accepted(cards: [shelfID(7)]))
    }

    @Test func oc6082_acceptedSingleCardCountsOneNotMore() {
        let end = ShelfDragEnd.resolve(accepted: true, sessionBegan: true, cards: one)
        guard case .accepted(let counted) = end else { Issue.record("expected accepted, got \(end)"); return }
        #expect(counted.count == 1)
        #expect(counted.first == shelfID(7))
    }

    // MARK: not accepted -> never carries cards, so no paste is recorded

    @Test func oc6082_notAcceptedAndBeganIsUserCancelWithNoError() {
        #expect(ShelfDragEnd.resolve(accepted: false, sessionBegan: true, cards: three) == .userCancelled)
        #expect(ShelfDragEnd.resolve(accepted: false, sessionBegan: true, cards: one) == .userCancelled)
    }

    @Test func oc6082_notAcceptedAndNeverBeganIsAbortWithShfOs001Error() {
        for cards in [one, three] {
            let end = ShelfDragEnd.resolve(accepted: false, sessionBegan: false, cards: cards)
            guard case .aborted(let error) = end else { Issue.record("expected aborted, got \(end)"); continue }
            #expect(error.code == .shfOs001)
            #expect(error.code.rawValue == "SHF-OS-001")
            #expect(error.severity == .error)
        }
    }

    @Test func oc6082_abortAndCancelNeverResolveToAccepted() {
        // pasteCount unchanged: the only case that carries cards to count is .accepted.
        for began in [true, false] {
            let end = ShelfDragEnd.resolve(accepted: false, sessionBegan: began, cards: three)
            if case .accepted = end { Issue.record("not-accepted (began=\(began)) resolved to accepted: \(end)") }
        }
    }

    // MARK: no cards -> nothing, all four flag combinations (empty boundary)

    @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
    func noCardsMeansNothingToCountOrReport(accepted: Bool, began: Bool) {
        #expect(ShelfDragEnd.resolve(accepted: accepted, sessionBegan: began, cards: []) == .none)
    }

    // MARK: stability

    @Test func resolveIsPureSameInputsSameResult() {
        let first = ShelfDragEnd.resolve(accepted: false, sessionBegan: false, cards: three)
        let second = ShelfDragEnd.resolve(accepted: false, sessionBegan: false, cards: three)
        #expect(first == second)
    }

    @Test func eachResultCaseIsDistinct() {
        let all: [ShelfDragEnd] = [
            .accepted(cards: one), .userCancelled, .aborted(FlotsamError(.shfOs001, "x")), .none
        ]
        for (i, a) in all.enumerated() { for (j, b) in all.enumerated() where i != j { #expect(a != b) } }
    }
}
