import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShelf

/// TASK-533: the top-centre placement (FR-006-01, FR-006-03, FR-006-05, FR-006-07). Geometry is asserted on exact
/// rectangles and the hover dwell on a fixed clock, so a changed constant, edge or boundary fails a test.
@Suite struct Task533TopCenterTests {
    /// A 1440 x 900 screen with a 25 pt menu bar at the top and a 60 pt Dock at the bottom.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let visible = CGRect(x: 0, y: 60, width: 1440, height: 815)

    private let origin = Date(timeIntervalSinceReferenceDate: 2_000_000)
    private func t(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    private func machine(hover: Bool, placement: ShelfPlacement = .topCenter) -> ShelfRevealMachine {
        var machine = ShelfRevealMachine()
        _ = machine.send(.configure(enabled: true, placement: placement, revealOnEdgeHover: hover), at: t(0))
        return machine
    }

    // MARK: Placement option

    @Test("the placement exists beside the four others and the default is unchanged")
    func optionExists() {
        #expect(ShelfPlacement.allCases == [.rightEdge, .leftEdge, .bottomEdge, .menuBar, .topCenter])
        #expect(ShelfPlacement.topCenter.rawValue == "topCenter")
        #expect(SettingKeys.shelfPlacement.defaultValue == .rightEdge)
    }

    // MARK: Hot zone

    @Test("the zone is a 4 pt strip at the physical top, over the middle 60 % of the width")
    func zone() throws {
        let zone = try #require(ShelfLayout.edgeZone(for: .topCenter, in: screen))
        #expect(zone == CGRect(x: 288, y: 896, width: 864, height: 4))
    }

    @Test("the zone follows a screen that is not at the origin")
    func zoneOnSecondaryScreen() throws {
        let secondary = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
        let zone = try #require(ShelfLayout.edgeZone(for: .topCenter, in: secondary))
        #expect(zone == CGRect(x: 1440 + 384, y: 896, width: 1152, height: 4))
    }

    @Test("zone boundaries: the last pixel row counts, 5 pt down does not, and the 20 % and 80 % columns bound it")
    func zoneBoundaries() {
        func hit(_ x: CGFloat, _ y: CGFloat) -> Int? {
            ShelfLayout.screenIndex(of: CGPoint(x: x, y: y), placement: .topCenter, screens: [screen])
        }
        #expect(hit(720, 900) == 0)
        #expect(hit(720, 896) == 0)
        #expect(hit(720, 895.9) == nil)
        #expect(hit(288, 899) == 0)
        #expect(hit(287.9, 899) == nil)
        #expect(hit(1152, 899) == 0)
        #expect(hit(1152.1, 899) == nil)
        #expect(hit(720, 0) == nil)
    }

    @Test("the other placements' zones do not match the top edge, and the top zone does not match theirs")
    func zonesAreDistinct() {
        let topPoint = CGPoint(x: 720, y: 899)
        for placement in [ShelfPlacement.rightEdge, .leftEdge, .bottomEdge, .menuBar] {
            #expect(ShelfLayout.screenIndex(of: topPoint, placement: placement, screens: [screen]) == nil)
        }
        let bottomPoint = CGPoint(x: 720, y: 1)
        #expect(ShelfLayout.screenIndex(of: bottomPoint, placement: .bottomEdge, screens: [screen]) == 0)
        #expect(ShelfLayout.screenIndex(of: bottomPoint, placement: .topCenter, screens: [screen]) == nil)
    }

    // MARK: Frame

    @Test("the row hangs from the top of the visible frame: 140 tall, centred, under the menu bar")
    func frameHangsFromMenuBar() {
        let frame = ShelfLayout.frame(for: .topCenter, in: visible, contentExtent: ShelfLayout.contentWidth(itemCount: 3))
        #expect(frame.height == 140)
        #expect(frame.maxY == visible.maxY)
        #expect(frame.midX == visible.midX)
        #expect(frame.width == ShelfLayout.contentWidth(itemCount: 3))
        #expect(visible.contains(frame))
    }

    @Test("a long row is capped at 80 % of the visible width and a short one is never narrower than a panel")
    func frameWidthRule() {
        let long = ShelfLayout.frame(for: .topCenter, in: visible, contentExtent: ShelfLayout.contentWidth(itemCount: 200))
        #expect(long.width == visible.width * 0.8)
        let empty = ShelfLayout.frame(for: .topCenter, in: visible, contentExtent: ShelfLayout.contentWidth(itemCount: 0))
        #expect(empty.width == 280)
    }

    @Test("the top-centre and bottom rows have the same size, differing only in which edge they hang from")
    func sameSizeAsBottom() {
        for extent in [ShelfLayout.contentWidth(itemCount: 0), ShelfLayout.contentWidth(itemCount: 5), 100_000] {
            let top = ShelfLayout.frame(for: .topCenter, in: visible, contentExtent: extent)
            let bottom = ShelfLayout.frame(for: .bottomEdge, in: visible, contentExtent: extent)
            #expect(top.size == bottom.size)
            #expect(top.minX == bottom.minX)
            #expect(top.minY != bottom.minY)
            #expect(bottom.minY == visible.minY)
        }
    }

    @Test("a tiny visible frame never yields a frame larger than itself")
    func tinyVisible() {
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 100)
        let frame = ShelfLayout.frame(for: .topCenter, in: tiny, contentExtent: 5_000)
        #expect(tiny.contains(frame))
        #expect(frame.maxY == tiny.maxY)
    }

    @Test("the row is horizontal and its cards are laid out as in the bottom strip")
    func horizontalRow() {
        #expect(ShelfLayout.isHorizontal(.topCenter))
        #expect(ShelfLayout.cardSize(for: .topCenter) == ShelfLayout.cardSize(for: .bottomEdge))
        #expect(ShelfLayout.cardSize(for: .topCenter).width == 112)
        #expect(!ShelfLayout.isHorizontal(.menuBar))
        #expect(!ShelfLayout.isHorizontal(.rightEdge))
    }

    // MARK: Slide

    @Test("the top-centre row slides in from above, to the top of the visible frame, keeping its x and size")
    func slideStart() {
        let frame = ShelfLayout.frame(for: .topCenter, in: visible, contentExtent: 600)
        let start = ShelfLayout.offscreenFrame(frame, placement: .topCenter, in: visible)
        #expect(start.minY == visible.maxY)
        #expect(start.minX == frame.minX)
        #expect(start.size == frame.size)
    }

    @Test("every other placement still slides from its own edge")
    func otherSlides() {
        let frame = CGRect(x: 500, y: 300, width: 280, height: 200)
        #expect(ShelfLayout.offscreenFrame(frame, placement: .rightEdge, in: visible).minX == visible.maxX)
        #expect(ShelfLayout.offscreenFrame(frame, placement: .leftEdge, in: visible).minX == visible.minX - 280)
        #expect(ShelfLayout.offscreenFrame(frame, placement: .bottomEdge, in: visible).minY == visible.minY - 200)
        #expect(ShelfLayout.offscreenFrame(frame, placement: .menuBar, in: visible).minY == visible.maxY)
    }

    // MARK: Pointer area (the hang strip)

    @Test("on the top-centre row the menu-bar strip above the panel counts as on the Shelf")
    func hangStripIsOnShelf() {
        let panel = ShelfLayout.frame(for: .topCenter, in: visible, contentExtent: 600)
        let area = ShelfLayout.pointerArea(for: .topCenter, panelFrame: panel, screenFrame: screen, menuBarStripCounts: true)
        #expect(area.maxY == screen.maxY)
        #expect(area.minY == panel.minY)
        #expect(area.minX == panel.minX && area.maxX == panel.maxX)
        // Where the pointer rests after the dwell: the zone's own pixel row, over the panel's columns.
        #expect(ShelfLayout.contains(area, CGPoint(x: panel.midX, y: 900)))
        #expect(ShelfLayout.contains(area, CGPoint(x: panel.midX, y: 899)))
        // Beside the panel the strip does not extend; neither does anything below it.
        #expect(!ShelfLayout.contains(area, CGPoint(x: panel.minX - 1, y: 899)))
        #expect(!ShelfLayout.contains(area, CGPoint(x: panel.midX, y: panel.minY - 1)))
    }

    @Test("with the menu bar hidden there is no strip, and other placements use the panel alone")
    func noStripElsewhere() {
        let flush = CGRect(x: 0, y: 60, width: 1440, height: 840)
        let panel = ShelfLayout.frame(for: .topCenter, in: flush, contentExtent: 600)
        #expect(ShelfLayout.pointerArea(for: .topCenter, panelFrame: panel, screenFrame: screen, menuBarStripCounts: true) == panel)
        let right = ShelfLayout.frame(for: .rightEdge, in: visible, contentExtent: 300)
        for placement in [ShelfPlacement.rightEdge, .leftEdge, .bottomEdge, .menuBar] {
            #expect(ShelfLayout.pointerArea(for: placement, panelFrame: right, screenFrame: screen, menuBarStripCounts: true) == right)
        }
    }

    @Test("a pointer on a border pixel is inside; one point beyond is outside")
    func containsIsInclusive() {
        let area = CGRect(x: 10, y: 20, width: 100, height: 50)
        #expect(ShelfLayout.contains(area, CGPoint(x: 10, y: 20)))
        #expect(ShelfLayout.contains(area, CGPoint(x: 110, y: 70)))
        #expect(!ShelfLayout.contains(area, CGPoint(x: 110.1, y: 70)))
        #expect(!ShelfLayout.contains(area, CGPoint(x: 110, y: 70.1)))
        #expect(!ShelfLayout.contains(area, CGPoint(x: 9.9, y: 20)))
        #expect(!ShelfLayout.contains(area, CGPoint(x: 10, y: 19.9)))
    }

    // MARK: Hover reveal and hide, on a fixed clock (FR-006-03b, FR-006-04)

    @Test("resting 500 ms in the top zone with hover on reveals a transient Shelf; 499 ms does not")
    func hoverReveals() {
        var m = machine(hover: true)
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: t(1))
        #expect(m.nextDeadline == t(1.5))
        #expect(m.advance(to: t(1.499)).isEmpty)
        #expect(!m.isVisible)
        #expect(m.advance(to: t(1.5)) == [.show(trigger: .hover, screen: 0)])
        #expect(m.visibleTrigger == .hover)
        #expect(!m.canBecomeKey)
    }

    @Test("with hover off, resting in the top zone for 5 s reveals nothing and arms no timer")
    func hoverOffDoesNothing() {
        var m = machine(hover: false)
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: t(1))
        #expect(m.nextDeadline == nil)
        #expect(m.advance(to: t(6)).isEmpty)
    }

    @Test("a drag resting 300 ms in the top zone reveals it")
    func dragReveals() {
        var m = machine(hover: false)
        _ = m.send(.dragging(true), at: t(1))
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: t(1))
        #expect(m.advance(to: t(1.299)).isEmpty)
        #expect(m.advance(to: t(1.3)) == [.show(trigger: .drag, screen: 0)])
    }

    @Test("a hover Shelf hides 600 ms after the pointer leaves, and not before; coming back cancels the hide")
    func hoverHides() {
        var m = machine(hover: true)
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: t(1))
        _ = m.advance(to: t(1.5))
        _ = m.send(.pointer(.onShelf), at: t(2))
        #expect(m.nextDeadline == nil)
        _ = m.send(.pointer(.away), at: t(3))
        #expect(m.nextDeadline == t(3.6))
        #expect(m.advance(to: t(3.599)).isEmpty)
        _ = m.send(.pointer(.onShelf), at: t(3.5))
        #expect(m.nextDeadline == nil)
        _ = m.send(.pointer(.away), at: t(4))
        #expect(m.advance(to: t(4.6)) == [.hide])
    }

    @Test("after a hide with the pointer still in the top zone it does not reveal again until the pointer has left")
    func noFlicker() {
        var m = machine(hover: true)
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: t(1))
        _ = m.advance(to: t(1.5))
        // The pointer stays in the zone (not on the panel): the Shelf hides, then must not re-arm.
        #expect(m.advance(to: t(2.1)) == [.hide])
        #expect(m.nextDeadline == nil)
        #expect(m.advance(to: t(9)).isEmpty)
        _ = m.send(.pointer(.away), at: t(10))
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: t(11))
        #expect(m.nextDeadline == t(11.5))
    }

    @Test("a hover Shelf on the top-centre placement hides on a click outside, and the hotkey shows a sticky one")
    func otherRules() {
        var m = machine(hover: true)
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: t(1))
        _ = m.advance(to: t(1.5))
        #expect(m.send(.clickOutside, at: t(2)) == [.hide])
        var sticky = machine(hover: false)
        #expect(sticky.send(.toggle(.hotkey, screen: 0), at: t(1)) == [.show(trigger: .hotkey, screen: 0)])
        #expect(sticky.canBecomeKey)
    }

    @Test("changing to or from the top-centre placement hides a visible Shelf")
    func placementChangeHides() {
        var m = machine(hover: true)
        _ = m.send(.pointer(.edgeZone(screen: 0)), at: t(1))
        _ = m.advance(to: t(1.5))
        #expect(m.send(.configure(enabled: true, placement: .bottomEdge, revealOnEdgeHover: true), at: t(2)) == [.hide])
    }

    @Test("the top-centre placement has no menu-bar-icon dwell: a drag over the icon reveals nothing")
    func noIconDwell() {
        var m = machine(hover: true)
        _ = m.send(.dragging(true), at: t(1))
        _ = m.send(.pointer(.menuBarIcon(screen: 0)), at: t(1))
        #expect(m.nextDeadline == nil)
    }
}
