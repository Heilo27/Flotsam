import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShelf

/// Drives the pure reveal machine on a fixed clock: `t(0.3)` is 300 ms after the start.
@Suite struct ShelfRevealMachineTests {
    private let origin = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func t(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    private func machine(
        placement: ShelfPlacement = .rightEdge,
        hover: Bool = false,
        enabled: Bool = true
    ) -> ShelfRevealMachine {
        var machine = ShelfRevealMachine()
        _ = machine.send(.configure(enabled: enabled, placement: placement, revealOnEdgeHover: hover), at: t(0))
        return machine
    }

    /// Sends `events` at `time`, returns the commands of all of them.
    @discardableResult
    private func send(_ machine: inout ShelfRevealMachine, _ events: [ShelfRevealMachine.Event], at time: TimeInterval) -> [ShelfRevealMachine.Command] {
        events.flatMap { machine.send($0, at: t(time)) }
    }

    private func settle(_ machine: inout ShelfRevealMachine, to time: TimeInterval) -> [ShelfRevealMachine.Command] {
        machine.advance(to: t(time))
    }

    // MARK: Drag dwell (FR-006-03a)

    @Test("OC-6013 a drag resting 300 ms in the edge zone reveals the Shelf")
    func dragDwellReveals() {
        var m = machine()
        send(&m, [.dragging(true), .buttonDown(true), .pointer(.edgeZone(screen: 0))], at: 1)
        #expect(m.nextDeadline == t(1.3))
        #expect(settle(&m, to: 1.299).isEmpty)
        #expect(settle(&m, to: 1.3) == [.show(trigger: .drag, screen: 0)])
        #expect(m.isVisible)
        #expect(!m.canBecomeKey)
    }

    @Test("OC-6014 a drag that leaves the zone after 150 ms reveals nothing and leaves no deadline")
    func shortDragDoesNothing() {
        var m = machine()
        send(&m, [.dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        send(&m, [.pointer(.away)], at: 1.15)
        #expect(m.nextDeadline == nil)
        #expect(settle(&m, to: 5).isEmpty)
        #expect(!m.isVisible)
    }

    @Test("OC-6013 jittering inside the same zone does not restart the dwell")
    func stableZoneKeepsDwell() {
        var m = machine()
        send(&m, [.dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1.2)
        #expect(m.nextDeadline == t(1.3))
    }

    @Test("OC-6018 a drag in the secondary screen's zone reveals on that screen; moving between zones restarts the dwell")
    func perScreenDwell() {
        var m = machine()
        send(&m, [.dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        send(&m, [.pointer(.edgeZone(screen: 1))], at: 1.2)
        #expect(m.nextDeadline == t(1.5))
        #expect(settle(&m, to: 1.5) == [.show(trigger: .drag, screen: 1)])
    }

    // MARK: Hover (FR-006-03b)

    @Test("OC-6015 with hover reveal off, resting 5 s at the edge shows nothing")
    func hoverOffNothing() {
        var m = machine(hover: false)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1)
        #expect(m.nextDeadline == nil)
        #expect(settle(&m, to: 6).isEmpty)
    }

    @Test("OC-6016 with hover on, 500 ms reveals; 300 ms then leaving does not")
    func hoverOn() {
        var m = machine(hover: true)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1)
        #expect(settle(&m, to: 1.499).isEmpty)
        #expect(settle(&m, to: 1.5) == [.show(trigger: .hover, screen: 0)])

        var other = machine(hover: true)
        send(&other, [.pointer(.edgeZone(screen: 0))], at: 1)
        send(&other, [.pointer(.away)], at: 1.3)
        #expect(settle(&other, to: 3).isEmpty)
        #expect(!other.isVisible)
    }

    @Test("OC-6016 hover needs no button down: with a button down and no drag nothing is revealed")
    func hoverNeedsNoButton() {
        var m = machine(hover: true)
        send(&m, [.buttonDown(true), .pointer(.edgeZone(screen: 0))], at: 1)
        #expect(m.nextDeadline == nil)
    }

    @Test("OC-6022 a window drag is not a content drag: the caller sends no dragging event and nothing is revealed")
    func windowDragIsNotADrag() {
        var m = machine(hover: false)
        send(&m, [.buttonDown(true), .pointer(.edgeZone(screen: 0))], at: 1)
        #expect(settle(&m, to: 2).isEmpty)
        #expect(!m.isVisible)
    }

    // MARK: Menu bar (FR-006-03d)

    @Test("OC-6019 menu-bar placement has no edge reveal, by drag or by hover")
    func menuBarNoEdge() {
        var m = machine(placement: .menuBar, hover: true)
        send(&m, [.dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        #expect(settle(&m, to: 3).isEmpty)
        var hover = machine(placement: .menuBar, hover: true)
        send(&hover, [.pointer(.edgeZone(screen: 0))], at: 1)
        #expect(settle(&hover, to: 3).isEmpty)
    }

    @Test("OC-6020 menu-bar placement: a drag on the icon for 300 ms reveals the Shelf")
    func menuBarIconDrag() {
        var m = machine(placement: .menuBar)
        send(&m, [.dragging(true), .pointer(.menuBarIcon(screen: 0))], at: 1)
        #expect(settle(&m, to: 1.3) == [.show(trigger: .menuBarIconDrag, screen: 0)])
    }

    @Test("OC-6020 the menu-bar icon reveals only for a drag, and only with menu-bar placement")
    func menuBarIconNeedsDragAndPlacement() {
        var noDrag = machine(placement: .menuBar)
        send(&noDrag, [.pointer(.menuBarIcon(screen: 0))], at: 1)
        #expect(noDrag.nextDeadline == nil)
        var edge = machine(placement: .rightEdge)
        send(&edge, [.dragging(true), .pointer(.menuBarIcon(screen: 0))], at: 1)
        #expect(edge.nextDeadline == nil)
    }

    @Test("OC-6020 a drop onto a menu-bar-revealed Shelf keeps it for 1.5 s and then 600 ms more")
    func menuBarDropHolds() {
        var m = machine(placement: .menuBar)
        send(&m, [.dragging(true), .pointer(.menuBarIcon(screen: 0))], at: 1)
        _ = settle(&m, to: 1.3)
        send(&m, [.pointer(.onShelf)], at: 1.4)
        send(&m, [.dropCompleted, .dragging(false)], at: 2)
        #expect(m.isVisible)
        send(&m, [.pointer(.away)], at: 2.1)
        #expect(settle(&m, to: 3.5).isEmpty)
        #expect(settle(&m, to: 4.1) == [.hide])
    }

    // MARK: Sticky (FR-006-03c, FR-006-04)

    @Test("OC-6024 the hotkey shows a sticky Shelf on the pointer's screen that survives 5 s away and a click outside")
    func hotkeySticky() {
        var m = machine()
        #expect(send(&m, [.toggle(.hotkey, screen: 1)], at: 1) == [.show(trigger: .hotkey, screen: 1)])
        send(&m, [.pointer(.away)], at: 1.1)
        #expect(settle(&m, to: 6.1).isEmpty)
        #expect(send(&m, [.clickOutside], at: 6.2).isEmpty)
        #expect(m.isVisible)
        #expect(m.canBecomeKey)
        #expect(m.nextDeadline == nil)
    }

    @Test("OC-6025 a sticky Shelf hides on the hotkey again, on the close button and on Esc")
    func stickyHides() {
        for hideEvents in [[ShelfRevealMachine.Event.toggle(.hotkey, screen: 0)], [.closeButton], [.escape]] {
            var m = machine()
            send(&m, [.toggle(.hotkey, screen: 0)], at: 1)
            #expect(send(&m, hideEvents, at: 2) == [.hide])
            #expect(!m.isVisible)
        }
    }

    @Test("OC-6021 the menu item shows a sticky Shelf, and choosing it again hides it")
    func menuItemToggles() {
        var m = machine(placement: .bottomEdge)
        #expect(send(&m, [.toggle(.menuItem, screen: 0)], at: 1) == [.show(trigger: .menuItem, screen: 0)])
        #expect(m.canBecomeKey)
        #expect(send(&m, [.toggle(.menuItem, screen: 0)], at: 2) == [.hide])
    }

    @Test("OC-6031 a paste hides a sticky Shelf")
    func pasteHidesSticky() {
        var m = machine()
        send(&m, [.toggle(.hotkey, screen: 0)], at: 1)
        #expect(send(&m, [.pasted], at: 2) == [.hide])
    }

    @Test("FR-006-03 a disabled Shelf ignores the hotkey and every dwell")
    func disabledIgnoresAll() {
        var m = machine(hover: true, enabled: false)
        #expect(send(&m, [.toggle(.hotkey, screen: 0)], at: 1).isEmpty)
        send(&m, [.dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        #expect(m.nextDeadline == nil)
    }

    @Test("FR-006-03 turning the Shelf off, or changing placement, hides it and drops its deadlines")
    func configureHides() {
        var m = machine(hover: true)
        send(&m, [.toggle(.hotkey, screen: 0)], at: 1)
        #expect(send(&m, [.configure(enabled: false, placement: .rightEdge, revealOnEdgeHover: true)], at: 2) == [.hide])
        #expect(m.nextDeadline == nil)

        var placed = machine()
        send(&placed, [.toggle(.hotkey, screen: 0)], at: 1)
        #expect(send(&placed, [.configure(enabled: true, placement: .leftEdge, revealOnEdgeHover: false)], at: 2) == [.hide])
    }

    // MARK: Transient hide (FR-006-04)

    @Test("OC-6026 a hover Shelf is still visible 500 ms after the pointer leaves it and hidden by 700 ms")
    func hoverLeaveHide() {
        var m = machine(hover: true)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1)
        _ = settle(&m, to: 1.5)
        send(&m, [.pointer(.onShelf)], at: 1.6)
        #expect(m.nextDeadline == nil)
        send(&m, [.pointer(.away)], at: 3)
        #expect(settle(&m, to: 3.5).isEmpty)
        #expect(m.isVisible)
        #expect(settle(&m, to: 3.7) == [.hide])
        #expect(!m.isVisible)
    }

    @Test("OC-6026 coming back to the Shelf within the delay cancels the hide")
    func returnCancelsHide() {
        var m = machine(hover: true)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1)
        _ = settle(&m, to: 1.5)
        send(&m, [.pointer(.onShelf)], at: 1.6)
        send(&m, [.pointer(.away)], at: 3)
        send(&m, [.pointer(.onShelf)], at: 3.4)
        #expect(settle(&m, to: 5).isEmpty)
        #expect(m.isVisible)
    }

    @Test("OC-6027 a drag Shelf stays during the drag and hides 600 ms after the drag ends away from it")
    func dragEndHide() {
        var m = machine()
        send(&m, [.dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        _ = settle(&m, to: 1.3)
        send(&m, [.pointer(.away)], at: 2)
        #expect(settle(&m, to: 9).isEmpty)
        #expect(m.nextDeadline == nil)
        send(&m, [.dragging(false)], at: 10)
        #expect(m.nextDeadline == t(10.6))
        #expect(settle(&m, to: 10.6) == [.hide])
    }

    @Test("OC-6028 an accepted drag-out hides a transient Shelf immediately, but not a sticky one")
    func dragOutAcceptedHides() {
        var m = machine()
        send(&m, [.dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        _ = settle(&m, to: 1.3)
        #expect(send(&m, [.dragOutAccepted], at: 2) == [.hide])

        var sticky = machine()
        send(&sticky, [.toggle(.hotkey, screen: 0)], at: 1)
        #expect(send(&sticky, [.dragOutAccepted], at: 2).isEmpty)
        #expect(sticky.isVisible)
    }

    @Test("OC-6029 a click outside hides a transient Shelf immediately")
    func clickOutsideHidesTransient() {
        var m = machine(hover: true)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1)
        _ = settle(&m, to: 1.5)
        send(&m, [.pointer(.onShelf)], at: 1.6)
        #expect(send(&m, [.clickOutside], at: 2) == [.hide])
    }

    @Test("OC-6056 Esc and the close button do nothing to a transient Shelf, which never becomes key")
    func transientIgnoresKeyboardClose() {
        var m = machine(hover: true)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1)
        _ = settle(&m, to: 1.5)
        send(&m, [.pointer(.onShelf)], at: 1.6)
        #expect(!m.canBecomeKey)
        #expect(send(&m, [.escape, .closeButton], at: 2).isEmpty)
        #expect(m.isVisible)
    }

    @Test("OC-6030 a Space change, the Library opening and a screen change hide any Shelf, sticky or transient")
    func spaceLibraryScreensHide() {
        for event in [ShelfRevealMachine.Event.spaceChanged, .libraryOpened, .screensChanged] {
            var sticky = machine()
            send(&sticky, [.toggle(.hotkey, screen: 0)], at: 1)
            #expect(send(&sticky, [event], at: 2) == [.hide])

            var transient = machine(hover: true)
            send(&transient, [.pointer(.edgeZone(screen: 0))], at: 1)
            _ = settle(&transient, to: 1.5)
            send(&transient, [.pointer(.onShelf)], at: 1.6)
            #expect(send(&transient, [event], at: 2) == [.hide])
        }
    }

    // MARK: Drop hold (FR-006-15)

    @Test("OC-6110 after a drop the Shelf is visible at 1.4 s and hidden by 2.2 s with the pointer away")
    func dropHold() {
        var m = machine()
        send(&m, [.dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        _ = settle(&m, to: 1.3)
        send(&m, [.pointer(.onShelf)], at: 1.5)
        // The drop lands at 10 s; the drag ends and the pointer moves away at once.
        send(&m, [.dropCompleted, .dragging(false), .pointer(.away)], at: 10)
        #expect(settle(&m, to: 11.4).isEmpty)
        #expect(m.isVisible)
        #expect(m.nextDeadline == t(12.1))
        #expect(settle(&m, to: 12.2) == [.hide])
    }

    @Test("OC-6110 the order of dropCompleted and dragging(false) does not change the deadline")
    func dropHoldOrderIndependent() {
        var m = machine()
        send(&m, [.dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        _ = settle(&m, to: 1.3)
        send(&m, [.dragging(false), .pointer(.away)], at: 10)
        send(&m, [.dropCompleted], at: 10)
        #expect(m.nextDeadline == t(12.1))
    }

    // MARK: Idle and re-arming (FR-006-17)

    @Test("OC-6110 an idle machine has no deadline; a sticky Shelf has none either")
    func idleHasNoDeadline() {
        var m = machine(hover: true)
        #expect(m.nextDeadline == nil)
        send(&m, [.pointer(.away), .dragging(false), .buttonDown(false)], at: 1)
        #expect(m.nextDeadline == nil)
        send(&m, [.toggle(.hotkey, screen: 0)], at: 2)
        send(&m, [.pointer(.away)], at: 3)
        #expect(m.nextDeadline == nil)
    }

    @Test("OC-6029 after a hide with the pointer still in the zone the Shelf does not re-show until the pointer leaves")
    func noReshowWhilePointerStaysInZone() {
        var m = machine(hover: true)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1)
        _ = settle(&m, to: 1.5)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1.6)
        // Pointer is in the zone but not on the panel: it hides 600 ms later and must not flicker back.
        #expect(settle(&m, to: 2.2) == [.hide])
        #expect(m.nextDeadline == nil)
        send(&m, [.pointer(.away)], at: 3)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 4)
        #expect(m.nextDeadline == t(4.5))
    }

    @Test("OC-6025 a hotkey press while a transient Shelf is visible hides it (the item is a toggle)")
    func toggleHidesTransient() {
        var m = machine(hover: true)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1)
        _ = settle(&m, to: 1.5)
        send(&m, [.pointer(.onShelf)], at: 1.6)
        #expect(send(&m, [.toggle(.hotkey, screen: 0)], at: 2) == [.hide])
    }

    @Test("OC-6013 advance applies a dwell that fell due between events at its own time, so the hide clock starts then")
    func lateAdvanceUsesDeadlineTime() {
        var m = machine()
        send(&m, [.dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        // A host that was suspended wakes at 5 s: the dwell fired at 1.3 s.
        let commands = m.send(.dragging(false), at: t(5))
        #expect(commands == [.show(trigger: .drag, screen: 0)])
        #expect(m.nextDeadline != nil)
    }

    // MARK: Stale state across a disable (FR-006-03)

    @Test("re-enabling forgets a button, drag and pointer reported while disabled: no dwell until a fresh report")
    func enableResetsStaleInputs() {
        var m = machine(hover: true, enabled: false)
        send(&m, [.buttonDown(true), .dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        send(&m, [.configure(enabled: true, placement: .rightEdge, revealOnEdgeHover: true)], at: 2)
        #expect(m.nextDeadline == nil)
        // The button is no longer held and no drag is running: a pointer in the zone is a hover dwell, not a drag dwell.
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 3)
        #expect(m.nextDeadline == t(3.5))
        #expect(settle(&m, to: 3.5) == [.show(trigger: .hover, screen: 0)])
    }

    @Test("an enable that changes nothing (already enabled) keeps the reported pointer")
    func reconfigureWhileEnabledKeepsInputs() {
        var m = machine(hover: true)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1)
        send(&m, [.configure(enabled: true, placement: .rightEdge, revealOnEdgeHover: true)], at: 1.2)
        #expect(m.nextDeadline == t(1.5))
    }

    // MARK: Drag and button end (the contract the App layer must honour on every way a gesture can end)

    @Test("a transient Shelf under a drag never hides; dragging(false) with the pointer away starts the 600 ms clock")
    func dragEndStartsHideClock() {
        var m = machine()
        send(&m, [.dragging(true), .pointer(.edgeZone(screen: 0))], at: 1)
        _ = settle(&m, to: 1.3)
        send(&m, [.pointer(.away)], at: 2)
        #expect(m.nextDeadline == nil)
        send(&m, [.dragging(false)], at: 3)
        #expect(m.nextDeadline == t(3.6))
        #expect(settle(&m, to: 3.6) == [.hide])
    }

    @Test("a button left down blocks the hover dwell; buttonDown(false) releases it")
    func buttonUpReleasesHover() {
        var m = machine(hover: true)
        send(&m, [.buttonDown(true), .pointer(.edgeZone(screen: 0))], at: 1)
        #expect(m.nextDeadline == nil)
        send(&m, [.buttonDown(false)], at: 2)
        #expect(m.nextDeadline == t(2.5))
    }
}
