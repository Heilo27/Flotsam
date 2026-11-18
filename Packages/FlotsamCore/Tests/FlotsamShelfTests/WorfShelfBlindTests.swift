import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf

// Blind QA of FRD-006 slice 5 (reveal triggers, hide rules, drop hold, drop highlight state). Written from
// `.claude/oracle/frd-006-contract.json` and the FRD, not from the implementation. Expected values are literals only.
// Each test names the code change that turns it red.

/// Drives the pure reveal machine on a fixed clock. Times are literal seconds from the start.
private struct Clock {
    let origin = Date(timeIntervalSinceReferenceDate: 2_000_000)
    func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }
}

private func armed(
    _ placement: ShelfPlacement = .rightEdge, hover: Bool = false
) -> (machine: ShelfRevealMachine, clock: Clock) {
    var m = ShelfRevealMachine()
    let clock = Clock()
    _ = m.send(.configure(enabled: true, placement: placement, revealOnEdgeHover: hover), at: clock.at(0))
    return (m, clock)
}

@Suite struct WorfShelfRevealBlindTests {

    // MARK: FR-006-03a / b dwell boundaries

    @Test("OC-6013 OC-6014 drag dwell: 299 ms shows nothing, 300 ms shows .drag on the screen; red if the dwell constant moves")
    func dragDwellBoundary() {
        // given a drag resting in the edge zone of screen 1 from t=0
        var (m, c) = armed()
        _ = m.send(.dragging(true), at: c.at(0))
        _ = m.send(.pointer(.edgeZone(screen: 1)), at: c.at(0))
        // when time advances to 299 ms then 300 ms
        let early = m.advance(to: c.at(0.299))
        let earlyVisible = m.isVisible
        let due = m.advance(to: c.at(0.300))
        // then nothing at 299 ms, exactly one show at 300 ms
        #expect(early == [])
        #expect(!earlyVisible)
        #expect(due == [.show(trigger: .drag, screen: 1)])
        #expect(m.visibleScreen == 1)
    }

    @Test("OC-6014 a 150 ms visit that leaves cancels the dwell and leaves no deadline; red if leave does not cancel")
    func shortVisitCancels() {
        var (m, c) = armed()
        _ = m.send(.dragging(true), at: c.at(0))
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        _ = m.send(.pointer(.away), at: c.at(0.150))
        let later = m.advance(to: c.at(5))
        #expect(later == [])
        #expect(!m.isVisible)
        #expect(m.nextDeadline == nil, "FR-006-17: an idle machine arms no timer")
    }

    @Test("OC-6015 OC-6016 hover dwell: off never reveals; on reveals at 500 ms (499 does not); button down blocks")
    func hoverDwell() {
        // off
        var (off, c) = armed(hover: false)
        _ = off.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        #expect(off.advance(to: c.at(5)) == [])
        #expect(!off.isVisible)
        // on: boundary
        var (on, _) = armed(hover: true)
        _ = on.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        #expect(on.advance(to: c.at(0.499)) == [])
        #expect(on.advance(to: c.at(0.500)) == [.show(trigger: .hover, screen: 0)])
        // on, but the button is down: never reveals however long it rests
        var (down, _) = armed(hover: true)
        _ = down.send(.buttonDown(true), at: c.at(0))
        _ = down.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        #expect(down.advance(to: c.at(5)) == [])
        #expect(!down.isVisible)
    }

    @Test("OC-6019 OC-6022 menu-bar placement ignores the edge zone; a non-drag pointer on the icon does not reveal")
    func menuBarPlacementEdgeAndIcon() {
        var (m, c) = armed(.menuBar, hover: true)
        _ = m.send(.dragging(true), at: c.at(0))
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        #expect(m.advance(to: c.at(1)) == [])
        _ = m.send(.dragging(false), at: c.at(1))
        _ = m.send(.pointer(.menuBarIcon(screen: 0)), at: c.at(1))
        #expect(m.advance(to: c.at(3)) == [], "the icon reveals only for a drag")
        #expect(!m.isVisible)
    }

    @Test("OC-6020 menu-bar placement: a drag on the icon reveals .menuBarIconDrag at 300 ms and a drop holds it")
    func menuBarIconDragRevealsAndDropHolds() {
        var (m, c) = armed(.menuBar)
        _ = m.send(.dragging(true), at: c.at(0))
        _ = m.send(.pointer(.menuBarIcon(screen: 0)), at: c.at(0))
        #expect(m.advance(to: c.at(0.299)) == [])
        #expect(m.advance(to: c.at(0.300)) == [.show(trigger: .menuBarIconDrag, screen: 0)])
        // the drop lands on the panel; the drag ends; the pointer is on the Shelf
        _ = m.send(.pointer(.onShelf), at: c.at(2))
        _ = m.send(.dropCompleted, at: c.at(2.05))
        _ = m.send(.dragging(false), at: c.at(2.05))
        #expect(m.advance(to: c.at(60)) == [], "a pointer resting on the Shelf never starts the leave timer")
        #expect(m.isVisible)
    }

    // MARK: FR-006-04 hide rules

    @Test("OC-6026 transient hover Shelf: still visible 500 ms after the pointer leaves, hidden by 700 ms")
    func hoverLeaveDelay() {
        var (m, c) = armed(hover: true)
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        _ = m.advance(to: c.at(0.5))
        _ = m.send(.pointer(.onShelf), at: c.at(1))
        _ = m.send(.pointer(.away), at: c.at(2))
        #expect(m.advance(to: c.at(2.5)) == [])
        #expect(m.isVisible)
        #expect(m.advance(to: c.at(2.7)) == [.hide])
        #expect(!m.isVisible)
    }

    @Test("OC-6027 a drag that ends away from the Shelf hides it 600 ms later (599 ms still visible)")
    func dragEndHidesAfterDelay() {
        var (m, c) = armed()
        _ = m.send(.dragging(true), at: c.at(0))
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        _ = m.advance(to: c.at(0.3))
        _ = m.send(.pointer(.away), at: c.at(1))
        #expect(m.advance(to: c.at(5)) == [], "while the drag continues the Shelf never hides")
        _ = m.send(.dragging(false), at: c.at(5))
        #expect(m.advance(to: c.at(5.599)) == [])
        #expect(m.isVisible)
        #expect(m.advance(to: c.at(5.600)) == [.hide])
    }

    @Test("OC-6028 OC-6029 transient: click outside and an accepted drag-out hide at once; sticky ignores both")
    func clickOutsideAndDragOutAcceptedOnlyHideTransient() {
        var (t1, c) = armed()
        _ = t1.send(.dragging(true), at: c.at(0))
        _ = t1.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        _ = t1.advance(to: c.at(0.3))
        #expect(t1.send(.clickOutside, at: c.at(0.4)) == [.hide])

        var (t2, _) = armed()
        _ = t2.send(.dragging(true), at: c.at(0))
        _ = t2.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        _ = t2.advance(to: c.at(0.3))
        #expect(t2.send(.dragOutAccepted, at: c.at(0.4)) == [.hide])

        var (sticky, _) = armed()
        _ = sticky.send(.toggle(.hotkey, screen: 0), at: c.at(0))
        #expect(sticky.send(.clickOutside, at: c.at(1)) == [])
        #expect(sticky.send(.dragOutAccepted, at: c.at(1)) == [])
        #expect(sticky.isVisible)
        #expect(sticky.send(.escape, at: c.at(2)) == [.hide], "Esc hides a sticky Shelf")
    }

    @Test("OC-6056 Esc does not hide a transient Shelf (a transient Shelf takes no keys) and it never becomes key")
    func escapeLeavesTransient() {
        var (m, c) = armed()
        _ = m.send(.dragging(true), at: c.at(0))
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        _ = m.advance(to: c.at(0.3))
        #expect(m.send(.escape, at: c.at(0.4)) == [])
        #expect(m.isVisible)
        #expect(!m.canBecomeKey)
    }

    // MARK: FR-006-15 / OC-6110 drop hold

    @Test("OC-6110 drop hold, pointer away: visible at 1.4 s after the drop, still at 2.099 s, hidden at 2.1 s")
    func dropHoldTimeline() {
        var (m, c) = armed()
        _ = m.send(.dragging(true), at: c.at(0))
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        _ = m.advance(to: c.at(0.3))
        // the drop completes at t=10; the drag ends and the pointer is away at the same instant
        _ = m.send(.dropCompleted, at: c.at(10))
        _ = m.send(.dragging(false), at: c.at(10))
        _ = m.send(.pointer(.away), at: c.at(10))
        #expect(m.advance(to: c.at(11.4)) == [])
        #expect(m.isVisible, "visible 1.4 s after the drop")
        #expect(m.advance(to: c.at(12.099)) == [])
        #expect(m.advance(to: c.at(12.100)) == [.hide], "1.5 s hold + 0.6 s leave delay")
    }

    @Test("OC-6110 a second drop inside the hold restarts it from the second drop; red if holdUntil is not replaced")
    func secondDropRestartsHold() {
        var (m, c) = armed()
        _ = m.send(.dragging(true), at: c.at(0))
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: c.at(0))
        _ = m.advance(to: c.at(0.3))
        _ = m.send(.dropCompleted, at: c.at(10))
        _ = m.send(.dragging(false), at: c.at(10))
        _ = m.send(.pointer(.away), at: c.at(10))
        _ = m.send(.dropCompleted, at: c.at(11))
        #expect(m.advance(to: c.at(13.099)) == [])
        #expect(m.isVisible, "second drop at 11 s holds until 12.5 s, hides at 13.1 s")
        #expect(m.advance(to: c.at(13.100)) == [.hide])
    }

    @Test("OC-6110 a drop completing while hidden leaves no hold behind: the next reveal hides 600 ms after the leave")
    func dropWhileHiddenDoesNotLeakIntoNextReveal() {
        // given a drop completes at t=1 while nothing is visible (a stale hold would run to 2.5 s)
        var (m, c) = armed()
        _ = m.send(.dropCompleted, at: c.at(1))
        #expect(!m.isVisible)
        // when a drag reveals the Shelf at 1.3 s and ends away from it at 1.5 s
        _ = m.send(.dragging(true), at: c.at(1))
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: c.at(1))
        _ = m.advance(to: c.at(1.3))
        _ = m.send(.dragging(false), at: c.at(1.5))
        _ = m.send(.pointer(.away), at: c.at(1.5))
        // then it hides at 2.1 s, not at 3.1 s
        #expect(m.advance(to: c.at(2.099)) == [])
        #expect(m.advance(to: c.at(2.100)) == [.hide], "no stale hold from the earlier drop")
    }

    @Test("FR-006-17 a visible sticky Shelf and an idle machine both report no deadline")
    func noTimersWhileIdleOrSticky() {
        var (m, c) = armed()
        #expect(m.nextDeadline == nil)
        _ = m.send(.toggle(.menuItem, screen: 0), at: c.at(0))
        #expect(m.isVisible)
        #expect(m.nextDeadline == nil)
        #expect(m.visibleTrigger == .menuItem)
        #expect(m.canBecomeKey)
    }
}

// MARK: Model: drop-target and highlight state (OC-6087, OC-6088, OC-6105, OC-6109, FR-006-12, FR-006-15)

@MainActor
@Suite struct WorfShelfDropStateBlindTests {
    private func rows(_ numbers: Range<Int>) -> [ItemRow] { numbers.map { makeShelfRow($0) } }

    @Test("OC-6088 the drop zone shows only while an acceptable drag is over: starts off, on, off again")
    func dropTargetedFollowsTheDrag() async {
        let rig = ShelfRig(rows: rows(1..<3))
        await rig.openSticky()
        #expect(rig.model.isDropTargeted == false)
        rig.model.setDropTargeted(true)
        #expect(rig.model.isDropTargeted == true)
        rig.model.setDropTargeted(true)
        #expect(rig.model.isDropTargeted == true, "repeated true is idempotent")
        rig.model.setDropTargeted(false)
        #expect(rig.model.isDropTargeted == false)
    }

    @Test("OC-6105 highlight marks exactly the dropped card and changes nothing else on the Shelf")
    func highlightMarksOneCard() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        let before = rig.model.sections()
        let selectionBefore = rig.model.selection
        #expect(rig.model.highlightedItemId == nil)
        rig.model.highlight(shelfID(2))
        #expect(rig.model.highlightedItemId == shelfID(2))
        #expect(rig.model.sections() == before, "highlight is presentation state, not content")
        #expect(rig.model.selection == selectionBefore, "highlight does not move the selection")
    }

    @Test("OC-6109 a second drop within the highlight window keeps its own highlight when the first one expires")
    func clearHighlightIsGuardedById() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.highlight(shelfID(1))
        rig.model.highlight(shelfID(3))
        rig.model.clearHighlight(of: shelfID(1))
        #expect(rig.model.highlightedItemId == shelfID(3), "the first drop's expiry must not clear the second's highlight")
        rig.model.clearHighlight(of: shelfID(3))
        #expect(rig.model.highlightedItemId == nil)
        rig.model.clearHighlight(of: shelfID(3))
        #expect(rig.model.highlightedItemId == nil, "clearing when nothing is highlighted is a no-op")
    }

    @Test("FR-006-15 hiding the Shelf clears both the drop zone and the highlight, and a reopened Shelf starts clean")
    func didHideClearsDropState() async {
        let rig = ShelfRig(rows: rows(1..<3))
        await rig.openSticky()
        rig.model.setDropTargeted(true)
        rig.model.highlight(shelfID(1))
        rig.model.didHide()
        #expect(rig.model.isDropTargeted == false)
        #expect(rig.model.highlightedItemId == nil)
        await rig.openSticky()
        #expect(rig.model.isDropTargeted == false)
        #expect(rig.model.highlightedItemId == nil)
    }

    @Test("OC-6087 a highlight for an id that is not on the Shelf changes no card and pastes nothing")
    func highlightOfUnknownIdIsHarmless() async {
        let rig = ShelfRig(rows: rows(1..<3))
        await rig.openSticky()
        let before = rig.model.sections()
        rig.model.highlight(shelfID(99))
        #expect(rig.model.sections() == before)
        #expect(rig.model.sections().flatMap(\.cards).count == 2)
        #expect(rig.paster.calls.isEmpty)
    }
}
