import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf

/// FRD-006 oracle contract tests, reveal/hide area (OC-6002..6005, 6008, 6009, 6012, 6115, 6122, 6123).
/// Each test drives the pure `ShelfRevealMachine` on a fixed clock, so no AppKit, panel or timer is involved.
/// Expected values are the oracle's literals (seconds, trigger names), never the machine's own constants.
@Suite struct Frd006ContractRevealTests {
    private let origin = Date(timeIntervalSinceReferenceDate: 2_000_000)
    private func t(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    private func machine(
        enabled: Bool = true, placement: ShelfPlacement = .rightEdge, hover: Bool = false
    ) -> ShelfRevealMachine {
        var machine = ShelfRevealMachine()
        _ = machine.send(.configure(enabled: enabled, placement: placement, revealOnEdgeHover: hover), at: t(0))
        return machine
    }

    @discardableResult
    private func send(_ m: inout ShelfRevealMachine, _ events: [ShelfRevealMachine.Event], at time: TimeInterval) -> [ShelfRevealMachine.Command] {
        events.flatMap { m.send($0, at: t(time)) }
    }

    // OC-6002. given the Shelf switched off, when the hotkey is pressed and a drag rests 1 s in the edge zone,
    // then nothing is shown. Red if `.toggle` or the drag dwell ignores `enabled`.
    @Test("OC-6002 a disabled Shelf ignores the hotkey toggle and a one-second drag dwell")
    func oc6002_disabledShelfShowsNothing() {
        var m = machine()
        send(&m, [.configure(enabled: false, placement: .rightEdge, revealOnEdgeHover: false)], at: 1)
        let toggled = send(&m, [.toggle(.hotkey, screen: 0)], at: 3)
        send(&m, [.dragging(true), .buttonDown(true), .pointer(.edgeZone(screen: 0))], at: 4)
        let dwelled = m.advance(to: t(5))
        #expect(toggled.isEmpty)
        #expect(dwelled.isEmpty)
        #expect(!m.isVisible)
        #expect(m.nextDeadline == nil)
    }

    // OC-6002. given a visible Shelf, when it is switched off, then it hides at once.
    @Test("OC-6002 switching the Shelf off while visible hides it")
    func oc6002_switchingOffHidesAVisibleShelf() {
        var m = machine()
        send(&m, [.toggle(.hotkey, screen: 0)], at: 1)
        #expect(m.isVisible)
        let commands = send(&m, [.configure(enabled: false, placement: .rightEdge, revealOnEdgeHover: false)], at: 2)
        #expect(commands == [.hide])
        #expect(!m.isVisible)
    }

    // OC-6003. given the Shelf was just turned off, when it is turned on again on the SAME machine (no relaunch),
    // then the hotkey shows it. Red if re-enabling needs a fresh machine.
    @Test("OC-6003 turning the Shelf back on without relaunching makes the hotkey work again")
    func oc6003_hotkeyWorksAfterReenable() {
        var m = machine()
        send(&m, [.configure(enabled: false, placement: .rightEdge, revealOnEdgeHover: false)], at: 1)
        #expect(send(&m, [.toggle(.hotkey, screen: 0)], at: 2).isEmpty)
        send(&m, [.configure(enabled: true, placement: .rightEdge, revealOnEdgeHover: false)], at: 3)
        #expect(send(&m, [.toggle(.hotkey, screen: 0)], at: 4) == [.show(trigger: .hotkey, screen: 0)])
        #expect(m.isVisible)
    }

    // OC-6003. a drag dwell of 300 ms reveals it again after re-enable; 299 ms does not.
    @Test("OC-6003 after re-enabling, a 300 ms drag dwell at the edge reveals the Shelf")
    func oc6003_dragDwellWorksAfterReenable() {
        var m = machine()
        send(&m, [.configure(enabled: false, placement: .rightEdge, revealOnEdgeHover: false)], at: 1)
        send(&m, [.configure(enabled: true, placement: .rightEdge, revealOnEdgeHover: false)], at: 2)
        send(&m, [.dragging(true), .buttonDown(true), .pointer(.edgeZone(screen: 0))], at: 10)
        #expect(m.advance(to: t(10.299)).isEmpty)
        #expect(m.advance(to: t(10.3)) == [.show(trigger: .drag, screen: 0)])
    }

    // OC-6004. given hover reveal on, then Shelf off: resting 2 s with no button, and dragging through the zone,
    // reveal nothing and leave no deadline (no observer left to wake the machine).
    @Test("OC-6004 a disabled Shelf with hover on reveals nothing and holds no deadline")
    func oc6004_disabledHoverAndDragLeaveNoDeadline() {
        var m = machine(hover: true)
        send(&m, [.configure(enabled: false, placement: .rightEdge, revealOnEdgeHover: true)], at: 1)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 2)
        #expect(m.nextDeadline == nil)
        #expect(m.advance(to: t(4)).isEmpty)
        send(&m, [.dragging(true), .buttonDown(true), .pointer(.away), .pointer(.edgeZone(screen: 0))], at: 5)
        #expect(m.nextDeadline == nil)
        #expect(m.advance(to: t(8)).isEmpty)
        #expect(!m.isVisible)
    }

    // OC-6004. negative control for the same setup: with the Shelf ON the identical hover does arm a deadline, so the
    // nil above is attributable to `enabled`, not to a machine that never arms.
    @Test("OC-6004 control: the same hover with the Shelf on arms a 500 ms deadline")
    func oc6004_enabledHoverDoesArmADeadline() {
        var m = machine(hover: true)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 2)
        #expect(m.nextDeadline == t(2.5))
    }

    // OC-6005. given menu-bar placement and the Shelf off, a drag onto the icon for 1 s shows no Shelf.
    @Test("OC-6005 menu-bar placement with the Shelf off: a drag on the icon reveals nothing")
    func oc6005_menuBarIconDragIgnoredWhenOff() {
        var m = machine(enabled: false, placement: .menuBar)
        send(&m, [.dragging(true), .buttonDown(true), .pointer(.menuBarIcon(screen: 0))], at: 1)
        #expect(m.advance(to: t(2)).isEmpty)
        #expect(!m.isVisible)
        #expect(m.nextDeadline == nil)
    }

    // OC-6008. given a drag reveal, Esc (cancelling the drag) does not make the Shelf key: it never becomes key, so
    // typing stays with TextEdit. Red if a transient Shelf may become key, or Esc promotes it.
    @Test("OC-6008 a drag-revealed Shelf never becomes key, including after Esc and the drag ending")
    func oc6008_dragRevealNeverKey() {
        var m = machine()
        send(&m, [.dragging(true), .buttonDown(true), .pointer(.edgeZone(screen: 0))], at: 1)
        _ = m.advance(to: t(1.3))
        #expect(m.visibleTrigger == .drag)
        #expect(!m.canBecomeKey)
        send(&m, [.escape, .dragging(false), .buttonDown(false)], at: 1.5)
        #expect(m.isVisible)
        #expect(!m.canBecomeKey)
    }

    // OC-6009. given hover reveal, after the 500 ms rest the Shelf is visible but not key, and stays not key while the
    // pointer moves away until it hides.
    @Test("OC-6009 a hover-revealed Shelf is not key while visible or while the pointer leaves")
    func oc6009_hoverRevealNeverKey() {
        var m = machine(hover: true)
        send(&m, [.pointer(.edgeZone(screen: 0))], at: 1)
        #expect(m.advance(to: t(1.5)) == [.show(trigger: .hover, screen: 0)])
        #expect(!m.canBecomeKey)
        send(&m, [.pointer(.away)], at: 1.6)
        #expect(m.isVisible)
        #expect(!m.canBecomeKey)
        #expect(m.advance(to: t(2.2)) == [.hide])
        #expect(!m.canBecomeKey)
    }

    // OC-6008/6009 contrast. a hotkey Shelf is the only kind that may become key.
    @Test("OC-6009 control: a hotkey-revealed Shelf can become key, so the two assertions above are not vacuous")
    func oc6009_controlStickyCanBecomeKey() {
        var m = machine()
        send(&m, [.toggle(.hotkey, screen: 0)], at: 1)
        #expect(m.canBecomeKey)
    }

    // OC-6012. given a hidden Shelf, a Space change followed by the hotkey shows it again.
    @Test("OC-6012 after a Space change the hotkey shows the Shelf, hidden or previously visible")
    func oc6012_hotkeyShowsAfterSpaceChange() {
        var m = machine()
        #expect(send(&m, [.spaceChanged], at: 1).isEmpty)
        #expect(send(&m, [.toggle(.hotkey, screen: 0)], at: 2) == [.show(trigger: .hotkey, screen: 0)])
        #expect(send(&m, [.spaceChanged], at: 3) == [.hide])
        #expect(send(&m, [.toggle(.hotkey, screen: 0)], at: 4) == [.show(trigger: .hotkey, screen: 0)])
        #expect(m.isVisible)
    }

    // OC-6115 (testable half: "no timers fire while idle"; the CPU < 0.5 % clause has no seam, manual).
    // given the Shelf enabled and hidden, 60 s of idling fires nothing and holds no deadline; then 60 s of continuous
    // dragging in the zone yields exactly one reveal in total and leaves no further deadline to poll.
    @Test("OC-6115 idle holds no deadline; a minute of continuous dragging yields one reveal and no pending timer")
    func oc6115_noTimersWhileIdleOrDragging() {
        var m = machine()
        #expect(m.nextDeadline == nil)
        #expect(m.advance(to: t(60)).isEmpty)
        send(&m, [.dragging(true), .buttonDown(true), .pointer(.edgeZone(screen: 0))], at: 61)
        #expect(m.nextDeadline == t(61.3))
        var shows: [ShelfRevealMachine.Command] = []
        for second in 62...121 {
            shows += send(&m, [.pointer(.edgeZone(screen: 0))], at: TimeInterval(second))
        }
        #expect(shows == [.show(trigger: .drag, screen: 0)])
        #expect(m.isVisible)
        #expect(m.nextDeadline == nil)
    }

    // OC-6122. given a Shelf visible on screen 1, when the display is disconnected it hides, and a drag dwell on screen 0
    // reveals it within 1 s.
    @Test("OC-6122 a screen change hides the Shelf and the main screen's edge then reveals it within 300 ms")
    func oc6122_screenRemovedHidesThenMainScreenReveals() {
        var m = machine()
        send(&m, [.toggle(.hotkey, screen: 1)], at: 1)
        #expect(m.visibleScreen == 1)
        #expect(send(&m, [.screensChanged], at: 2) == [.hide])
        #expect(!m.isVisible)
        send(&m, [.pointer(.away), .dragging(true), .buttonDown(true), .pointer(.edgeZone(screen: 0))], at: 3)
        #expect(m.advance(to: t(3.3)) == [.show(trigger: .drag, screen: 0)])
        #expect(m.visibleScreen == 0)
    }

    // OC-6123. given one screen, when a second is connected, a drag dwell at the new screen's edge reveals the Shelf there.
    @Test("OC-6123 a connected display's edge reveals the Shelf on that display within 300 ms")
    func oc6123_newScreenEdgeReveals() {
        var m = machine()
        #expect(send(&m, [.screensChanged], at: 1).isEmpty)
        send(&m, [.dragging(true), .buttonDown(true), .pointer(.edgeZone(screen: 1))], at: 2)
        #expect(m.advance(to: t(2.299)).isEmpty)
        #expect(m.advance(to: t(2.3)) == [.show(trigger: .drag, screen: 1)])
        #expect(m.visibleScreen == 1)
    }
}
