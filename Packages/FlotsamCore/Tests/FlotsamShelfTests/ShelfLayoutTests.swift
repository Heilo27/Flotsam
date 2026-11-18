import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShelf

@Suite struct ShelfLayoutTests {
    /// A 1440 x 900 screen at the origin, with a 25 pt menu bar and a 60 pt Dock on the right.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let visible = CGRect(x: 0, y: 0, width: 1380, height: 875)

    // MARK: Hot zone (FR-006-03)

    @Test("OC-6017 the edge zone is 4 pt thick over the middle 60 % of the right edge")
    func rightEdgeZone() throws {
        let zone = try #require(ShelfLayout.edgeZone(for: .rightEdge, in: screen))
        #expect(zone == CGRect(x: 1436, y: 180, width: 4, height: 540))
        // Top 15 % of the edge length: outside. Mid-height at the edge: inside. 20 pt in from the edge: outside.
        #expect(ShelfLayout.screenIndex(of: CGPoint(x: 1439, y: 900 * 0.85), placement: .rightEdge, screens: [screen]) == nil)
        #expect(ShelfLayout.screenIndex(of: CGPoint(x: 1439, y: 450), placement: .rightEdge, screens: [screen]) == 0)
        #expect(ShelfLayout.screenIndex(of: CGPoint(x: 1420, y: 450), placement: .rightEdge, screens: [screen]) == nil)
    }

    @Test("OC-6017 the zone's last pixel row counts, and the middle 60 % starts at 20 %")
    func zoneBoundaries() {
        #expect(ShelfLayout.screenIndex(of: CGPoint(x: 1440, y: 450), placement: .rightEdge, screens: [screen]) == 0)
        #expect(ShelfLayout.screenIndex(of: CGPoint(x: 1439, y: 179), placement: .rightEdge, screens: [screen]) == nil)
        #expect(ShelfLayout.screenIndex(of: CGPoint(x: 1439, y: 180), placement: .rightEdge, screens: [screen]) == 0)
        #expect(ShelfLayout.screenIndex(of: CGPoint(x: 1439, y: 720), placement: .rightEdge, screens: [screen]) == 0)
        #expect(ShelfLayout.screenIndex(of: CGPoint(x: 1439, y: 721), placement: .rightEdge, screens: [screen]) == nil)
    }

    @Test("OC-6017 left and bottom placements mirror the zone onto their own edge")
    func leftAndBottomZones() throws {
        let left = try #require(ShelfLayout.edgeZone(for: .leftEdge, in: screen))
        #expect(left == CGRect(x: 0, y: 180, width: 4, height: 540))
        let bottom = try #require(ShelfLayout.edgeZone(for: .bottomEdge, in: screen))
        #expect(bottom == CGRect(x: 288, y: 0, width: 864, height: 4))
    }

    @Test("OC-6019 the menu-bar placement has no edge zone")
    func menuBarHasNoZone() {
        #expect(ShelfLayout.edgeZone(for: .menuBar, in: screen) == nil)
        #expect(ShelfLayout.screenIndex(of: CGPoint(x: 1439, y: 450), placement: .menuBar, screens: [screen]) == nil)
    }

    @Test("OC-6018 the zone of a secondary screen resolves to that screen's index")
    func secondaryScreenZone() {
        let secondary = CGRect(x: 1440, y: 100, width: 1920, height: 1080)
        let hit = ShelfLayout.screenIndex(of: CGPoint(x: 3359, y: 640), placement: .rightEdge, screens: [screen, secondary])
        #expect(hit == 1)
    }

    // MARK: Frames (FR-006-05)

    @Test("OC-6032 the right-edge frame lies inside the visible frame, so the Dock is not covered")
    func rightFrameInsideVisible() {
        let frame = ShelfLayout.frame(for: .rightEdge, in: visible, contentExtent: 300)
        #expect(visible.contains(frame))
        #expect(frame.maxX == visible.maxX)
        #expect(frame.maxX <= screen.maxX - 60)
    }

    @Test("OC-6034 right edge: 280 wide, at least 160 tall with one item, visible height minus 40 with forty, centred")
    func rightEdgeHeights() {
        let one = ShelfLayout.frame(for: .rightEdge, in: visible, contentExtent: ShelfLayout.contentHeight(pinnedCount: 0, recentCount: 1))
        #expect(one.width == 280)
        #expect(one.height >= 160)
        #expect(one.midY == visible.midY)

        let forty = ShelfLayout.frame(for: .rightEdge, in: visible, contentExtent: ShelfLayout.contentHeight(pinnedCount: 20, recentCount: 20))
        #expect(forty.width == 280)
        #expect(forty.height == visible.height - 40)
        #expect(forty.midY == visible.midY)
    }

    @Test("OC-6034 left edge sits on the left of the visible frame with the same sizes")
    func leftEdgeFrame() {
        let frame = ShelfLayout.frame(for: .leftEdge, in: visible, contentExtent: 100_000)
        #expect(frame.minX == visible.minX)
        #expect(frame.width == 280)
        #expect(frame.height == visible.height - 40)
    }

    @Test("OC-6034 a tiny visible frame never produces a frame larger than itself")
    func tinyVisibleFrame() {
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 120)
        let frame = ShelfLayout.frame(for: .rightEdge, in: tiny, contentExtent: 500)
        #expect(tiny.contains(frame))
    }

    @Test("OC-6033 bottom edge: 140 tall, at most 80 % of the width, centred")
    func bottomFrame() {
        let thirty = ShelfLayout.frame(for: .bottomEdge, in: visible, contentExtent: ShelfLayout.contentWidth(itemCount: 30))
        #expect(thirty.height == 140)
        #expect(thirty.width == visible.width * 0.8)
        #expect(thirty.midX == visible.midX)
        #expect(thirty.minY == visible.minY)
        #expect(visible.contains(thirty))

        let two = ShelfLayout.frame(for: .bottomEdge, in: visible, contentExtent: ShelfLayout.contentWidth(itemCount: 2))
        #expect(two.width < visible.width * 0.8)
        #expect(two.midX == visible.midX)
    }

    @Test("OC-6035 menu bar: 280 wide, top directly under the icon, fully on screen near the right edge")
    func menuBarFrame() {
        let icon = CGRect(x: 1390, y: 875, width: 24, height: 25)
        let area = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let frame = ShelfLayout.frame(for: .menuBar, in: area, contentExtent: 400, menuBarIcon: icon)
        #expect(frame.width == 280)
        #expect(frame.maxY == icon.minY)
        #expect(area.contains(frame))
    }

    @Test("OC-6035 menu bar: centred under an icon in the middle of the screen")
    func menuBarCentred() {
        let icon = CGRect(x: 700, y: 875, width: 24, height: 25)
        let area = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let frame = ShelfLayout.frame(for: .menuBar, in: area, contentExtent: 400, menuBarIcon: icon)
        #expect(frame.midX == icon.midX)
    }

    // MARK: Cards and motion

    @Test("OC-6048 vertical cards are 64 pt tall; bottom cards are 112 pt wide")
    func cardSizes() {
        #expect(ShelfLayout.cardSize(for: .rightEdge).height == 64)
        #expect(ShelfLayout.cardSize(for: .leftEdge).height == 64)
        #expect(ShelfLayout.cardSize(for: .menuBar).height == 64)
        #expect(ShelfLayout.cardSize(for: .bottomEdge).width == 112)
        #expect(ShelfLayout.isHorizontal(.bottomEdge))
        #expect(!ShelfLayout.isHorizontal(.rightEdge))
    }

    @Test("OC-6040 an empty Shelf has the minimum height and the vertical width")
    func emptyContentExtent() {
        #expect(ShelfLayout.contentHeight(pinnedCount: 0, recentCount: 0) == 160)
        #expect(ShelfLayout.contentWidth(itemCount: 0) == 280)
    }

    @Test("OC-6036 slide in over 150 ms, out over 120 ms; fade over 100 ms with Reduce Motion")
    func transitions() {
        let slide = ShelfLayout.transition(reduceMotion: false)
        #expect(slide.style == .slide)
        #expect(slide.showDuration == 0.150)
        #expect(slide.hideDuration == 0.120)
        let fade = ShelfLayout.transition(reduceMotion: true)
        #expect(fade.style == .fade)
        #expect(fade.showDuration == 0.100)
        #expect(fade.hideDuration == 0.100)
    }
}
