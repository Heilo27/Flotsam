import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShelf

/// Worf's adversarial pass on TASK-533 (top-centre placement). Each test names the change that turns it red.
/// All expected values are literal rectangles and points; none is computed with `ShelfLayout`.
@Suite struct Worf533TopCenterAdversarialTests {
    private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func hit(_ placement: ShelfPlacement, _ x: CGFloat, _ y: CGFloat, screens: [CGRect]) -> Int? {
        ShelfLayout.screenIndex(of: CGPoint(x: x, y: y), placement: placement, screens: screens)
    }

    // MARK: Per-screen top (red if the zone's top is taken from the highest screen, or from the main screen)

    @Test("a secondary screen whose top is ABOVE the main screen's gets its zone at its own top, not at the main's")
    func zoneOnHigherSecondary() throws {
        let higher = CGRect(x: 1440, y: 300, width: 1920, height: 1080)  // top at 1380, main's top is 900
        let zone = try #require(ShelfLayout.edgeZone(for: .topCenter, in: higher))
        #expect(zone == CGRect(x: 1824, y: 1376, width: 1152, height: 4))
        #expect(hit(.topCenter, 2400, 1379, screens: [main, higher]) == 1)
        // The main screen's own top row is not on the secondary's zone and the secondary is not "at 900".
        #expect(hit(.topCenter, 2400, 899, screens: [main, higher]) == nil)
    }

    @Test("a secondary screen whose top is BELOW the main screen's gets its zone at its own top")
    func zoneOnLowerSecondary() throws {
        let lower = CGRect(x: 1440, y: -500, width: 1920, height: 1080)  // top at 580
        let zone = try #require(ShelfLayout.edgeZone(for: .topCenter, in: lower))
        #expect(zone == CGRect(x: 1824, y: 576, width: 1152, height: 4))
        #expect(hit(.topCenter, 2400, 579, screens: [main, lower]) == 1)
        #expect(hit(.topCenter, 2400, 899, screens: [main, lower]) == nil)
    }

    @Test("each of two side-by-side screens reveals with its own index, and the index is the screen's, not the first match")
    func indexIsTheRightScreen() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(hit(.topCenter, 720, 899, screens: [main, right]) == 0)
        #expect(hit(.topCenter, 2400, 1079, screens: [main, right]) == 1)
        #expect(hit(.topCenter, 2400, 1079, screens: [right, main]) == 0)
    }

    // MARK: Pointer area on another screen and on notch / auto-hide screens

    @Test("the hang strip reaches the top of the panel's own screen, which is not the global top")
    func pointerAreaOnHigherSecondary() {
        let higher = CGRect(x: 1440, y: 300, width: 1920, height: 1080)
        let visible = CGRect(x: 1440, y: 300, width: 1920, height: 1055)  // 25 pt menu bar
        let panel = ShelfLayout.frame(for: .topCenter, in: visible, contentExtent: 600)
        let area = ShelfLayout.pointerArea(for: .topCenter, panelFrame: panel, screenFrame: higher, menuBarStripCounts: true)
        #expect(area == CGRect(x: 2400 - 300, y: 1215, width: 600, height: 165))  // 140 panel + 25 strip
        #expect(ShelfLayout.contains(area, CGPoint(x: 2400, y: 1380)))
        #expect(!ShelfLayout.contains(area, CGPoint(x: 2400, y: 1380.1)))
    }

    @Test("a notched screen: the strip is the whole notch-height menu bar, so the pointer at the physical top is on the row")
    func notchStrip() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)  // 38 pt menu bar beside the notch
        let panel = ShelfLayout.frame(for: .topCenter, in: visible, contentExtent: 600)
        #expect(panel == CGRect(x: 456, y: 804, width: 600, height: 140))
        #expect(!screen.contains(CGPoint(x: 756, y: 982)))  // the pointer-at-maxY premise of the inclusive rule
        let area = ShelfLayout.pointerArea(for: .topCenter, panelFrame: panel, screenFrame: screen, menuBarStripCounts: true)
        #expect(area == CGRect(x: 456, y: 804, width: 600, height: 178))
    }

    @Test("an auto-hidden menu bar: visible equals the screen, the panel touches the top and the pointer at the top is on it")
    func autoHiddenMenuBar() {
        let panel = ShelfLayout.frame(for: .topCenter, in: main, contentExtent: 600)
        #expect(panel == CGRect(x: 420, y: 760, width: 600, height: 140))
        let area = ShelfLayout.pointerArea(for: .topCenter, panelFrame: panel, screenFrame: main, menuBarStripCounts: true)
        #expect(area == panel)
        #expect(ShelfLayout.contains(area, CGPoint(x: 720, y: 900)))
    }

    @Test("with the Dock on the left the row is centred in the visible frame, not in the screen")
    func dockOnTheLeft() {
        let visible = CGRect(x: 80, y: 0, width: 1360, height: 875)
        let panel = ShelfLayout.frame(for: .topCenter, in: visible, contentExtent: 600)
        #expect(panel == CGRect(x: 460, y: 735, width: 600, height: 140))
    }

    // MARK: contains is now inclusive for every placement

    @Test("the panel frames of the four older placements still contain their own corners and nothing one point beyond")
    func olderPlacementsContainsBoundaries() {
        let visible = CGRect(x: 0, y: 60, width: 1440, height: 815)
        let right = ShelfLayout.frame(for: .rightEdge, in: visible, contentExtent: 300)
        #expect(right == CGRect(x: 1160, y: 317.5, width: 280, height: 300))
        #expect(ShelfLayout.contains(right, CGPoint(x: 1440, y: 400)))
        #expect(!ShelfLayout.contains(right, CGPoint(x: 1440.1, y: 400)))
        let left = ShelfLayout.frame(for: .leftEdge, in: visible, contentExtent: 300)
        #expect(ShelfLayout.contains(left, CGPoint(x: 0, y: 400)))
        #expect(!ShelfLayout.contains(left, CGPoint(x: -0.1, y: 400)))
        let bottom = ShelfLayout.frame(for: .bottomEdge, in: visible, contentExtent: 600)
        #expect(bottom == CGRect(x: 420, y: 60, width: 600, height: 140))
        #expect(ShelfLayout.contains(bottom, CGPoint(x: 720, y: 60)))
        #expect(!ShelfLayout.contains(bottom, CGPoint(x: 720, y: 59.9)))  // the Dock side stays outside
    }

    // MARK: Minimum width (kills the M21 survivor: dropping `max(contentExtent, panelWidth)`)

    @Test("a short row (extent 100) is never narrower than a 280 pt panel, on the top-centre and bottom rows alike")
    func shortRowKeepsMinimumWidth() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let top = ShelfLayout.frame(for: .topCenter, in: visible, contentExtent: 100)
        #expect(top == CGRect(x: 580, y: 760, width: 280, height: 140))
        let bottom = ShelfLayout.frame(for: .bottomEdge, in: visible, contentExtent: 100)
        #expect(bottom == CGRect(x: 580, y: 25, width: 280, height: 140))
    }

    // MARK: Seams between screens (the inclusive far border; see the known issues)

    @Test("two screens side by side: the pointer on the FIRST column of the right screen is not reported on the LEFT screen's right edge zone")
    func rightEdgeSeamBelongsToTheRightScreen() {
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        // The seam column is the right screen's first column, so it is not the left screen's zone (F2).
        #expect(hit(.rightEdge, 1440, 450, screens: [left, right]) == nil)
        // The last column that really is the left screen's still reveals.
        #expect(hit(.rightEdge, 1439.5, 450, screens: [left, right]) == 0)
    }

    @Test("two screens stacked: the pointer on the BOTTOM row of the upper screen is not reported on the lower screen's top-centre zone")
    func topCenterSeamBelongsToTheUpperScreen() {
        let upper = CGRect(x: 0, y: 900, width: 1440, height: 900)
        // The seam row is the upper screen's first row, so it is not the lower screen's top zone (F3).
        #expect(hit(.topCenter, 720, 900, screens: [main, upper]) == nil)
        // The real top of the upper screen is its zone, and the seam's own row just below the join is the lower's.
        #expect(hit(.topCenter, 720, 1799, screens: [main, upper]) == 1)
        #expect(hit(.topCenter, 720, 899.5, screens: [main, upper]) == 0)
    }

    // MARK: Degenerate areas

    @Test("an empty area contains nothing, so a not-yet-positioned panel cannot claim the pointer")
    func emptyAreaContainsNothing() {
        #expect(!ShelfLayout.contains(.zero, .zero))  // F4
        #expect(!ShelfLayout.contains(.null, CGPoint(x: 5, y: 5)))
    }

    @Test("pointerArea never shrinks the panel and never extends sideways, for any screen above or equal to the panel top")
    func pointerAreaIsAtLeastThePanel() {
        let panel = CGRect(x: 420, y: 700, width: 600, height: 140)
        for top in [840, 841, 865, 900, 1000] as [CGFloat] {
            let screen = CGRect(x: 0, y: 0, width: 1440, height: top)
            let area = ShelfLayout.pointerArea(for: .topCenter, panelFrame: panel, screenFrame: screen, menuBarStripCounts: true)
            #expect(area.minX == 420 && area.maxX == 1020 && area.minY == 700)
            #expect(area.maxY == max(top, 840))
        }
    }
}
