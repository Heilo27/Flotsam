import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShelf

/// TASK-533 F1/F2/F3/F5: the controller's pointer decision (`ShelfPointerClassifier`) fed by a scripted pointer, with
/// the reveal machine on a fixed clock behind it. Every point and rectangle is a literal.
@Suite struct Task533PointerClassifierTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// The row: 600 pt wide, 140 pt tall, hung from the 875 pt top of the visible frame (25 pt menu bar above it).
    private let panel = CGRect(x: 420, y: 735, width: 600, height: 140)
    private let origin = Date(timeIntervalSinceReferenceDate: 3_000_000)
    private func t(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    private func region(
        _ x: CGFloat, _ y: CGFloat, visible: Bool = true, hover: Bool, screens: [CGRect]? = nil, placement: ShelfPlacement = .topCenter
    ) -> ShelfRevealMachine.Pointer {
        ShelfPointerClassifier.region(
            at: CGPoint(x: x, y: y), placement: placement, isVisible: visible, panelFrame: panel, screenFrame: screen,
            hoverMonitored: hover, screens: screens ?? [screen], menuBarIcon: nil)
    }

    /// A transient top-centre Shelf revealed by a drag dwell with hover off; the drag has ended with the pointer on the row.
    private func dragRevealedMachine(hover: Bool) -> ShelfRevealMachine {
        var m = ShelfRevealMachine()
        _ = m.send(.configure(enabled: true, placement: .topCenter, revealOnEdgeHover: hover), at: t(0))
        _ = m.send(.dragging(true), at: t(1))
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: t(1))
        _ = m.advance(to: t(1.3))
        _ = m.send(.pointer(.onShelf), at: t(2))
        _ = m.send(.dragging(false), at: t(2))
        return m
    }

    // MARK: F1 (menu-bar strip counts only while the hover monitor reports it)

    @Test("hover off: the pointer in the menu-bar strip above the row is not on the Shelf")
    func stripIsNotOnShelfWithHoverOff() {
        #expect(region(720, 880, hover: false) == .away)
        #expect(region(720, 899, hover: false) == .edgeZone(screen: 0))
        #expect(region(720, 900, hover: false) == .edgeZone(screen: 0))
        #expect(region(720, 874, hover: false) == .onShelf)
    }

    @Test("hover on: the strip is on the Shelf, so the pointer that revealed the row can rest at the top")
    func stripIsOnShelfWithHoverOn() {
        #expect(region(720, 880, hover: true) == .onShelf)
        #expect(region(720, 900, hover: true) == .onShelf)
        // Still only over the row's columns.
        #expect(region(419, 880, hover: true) == .away)
        #expect(region(1021, 880, hover: true) == .away)
    }

    @Test("hover off, exit upward into the strip: the 600 ms hide is scheduled (the stuck-Shelf case)")
    func exitUpwardSchedulesHide() {
        var m = dragRevealedMachine(hover: false)
        #expect(m.nextDeadline == nil)
        // The scripted pointer: on the row, then up one pixel row at a time into the strip; each report is what the
        // controller would send, and only a change of region is sent.
        var last: ShelfRevealMachine.Pointer?
        for (seconds, y) in [(3, 800), (3.5, 874), (4, 880), (4.5, 899)] as [(TimeInterval, CGFloat)] {
            let now = region(720, y, hover: false)
            if now != last { _ = m.send(.pointer(now), at: t(seconds)); last = now }
        }
        // The first report that left the row was at 4 (y 880, away); the later strip pixel is another region and
        // does not push the leave back.
        #expect(m.nextDeadline == t(4.6))
        #expect(m.advance(to: t(4.599)).isEmpty)
        #expect(m.advance(to: t(4.6)) == [.hide])
    }

    @Test("hover on, the same upward move stays on the Shelf, and the hide comes only when the pointer leaves the strip sideways")
    func hoverOnStripKeepsShelf() {
        var m = dragRevealedMachine(hover: true)
        _ = m.send(.pointer(region(720, 880, hover: true)), at: t(3))
        _ = m.send(.pointer(region(720, 900, hover: true)), at: t(3.1))
        #expect(m.nextDeadline == nil)
        _ = m.send(.pointer(region(1200, 899, hover: true)), at: t(4))
        #expect(m.nextDeadline == t(4.6))
    }

    @Test("a hidden Shelf has no area: the same point is an edge zone or away, never on the Shelf")
    func hiddenIsNeverOnShelf() {
        #expect(region(720, 800, visible: false, hover: true) == .away)
        #expect(region(720, 899, visible: false, hover: true) == .edgeZone(screen: 0))
    }

    // MARK: F2/F3/F5 (one screen lookup, half-open, with the physical top row kept)

    @Test("the seam column and row belong to exactly one screen, and every lookup agrees")
    func seamBelongsToOneScreen() {
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: 1440, y: 450), in: [left, right]) == 1)
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: 1439.5, y: 450), in: [left, right]) == 0)
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: 720, y: 900), in: [left, above]) == 1)
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: 720, y: 899.5), in: [left, above]) == 0)
        // Order of the list does not move the seam.
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: 1440, y: 450), in: [right, left]) == 0)
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: 720, y: 900), in: [above, left]) == 0)
    }

    @Test("the physical top row of a screen with nothing above it still resolves to that screen, so the zone is reachable")
    func physicalTopRowResolves() {
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: 720, y: 900), in: [screen]) == 0)
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: 1440, y: 450), in: [screen]) == 0)
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: 1440, y: 900), in: [screen]) == 0)
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: 720, y: 900.5), in: [screen]) == nil)
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: -0.5, y: 450), in: [screen]) == nil)
        #expect(region(720, 900, visible: false, hover: false) == .edgeZone(screen: 0))
        // Beside a screen on the right, the top row of the left one still resolves to it (nothing is above it).
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(ShelfLayout.screenIndex(containing: CGPoint(x: 720, y: 900), in: [screen, right]) == 0)
        #expect(region(720, 900, visible: false, hover: false, screens: [screen, right]) == .edgeZone(screen: 0))
    }

    @Test("the menu-bar icon's screen is the screen lookup's, so the icon on the seam column is the right screen's")
    func iconScreenUsesTheOneLookup() {
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let icon = CGRect(x: 1430, y: 880, width: 20, height: 20)
        let at = ShelfPointerClassifier.region(
            at: CGPoint(x: 1440, y: 890), placement: .menuBar, isVisible: false, panelFrame: .zero, screenFrame: nil,
            hoverMonitored: false, screens: [left, right], menuBarIcon: icon)
        #expect(at == .menuBarIcon(screen: 1))
    }
}
