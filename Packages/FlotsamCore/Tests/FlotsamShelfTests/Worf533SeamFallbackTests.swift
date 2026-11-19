import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShelf

/// TASK-533 re-QA (2): the closed fallback of `ShelfLayout.screenIndex(containing:in:)` on layouts with gaps, outer
/// borders and a taller neighbour. Every rectangle and point is a literal; the expected side names no production symbol.
@Suite struct Worf533SeamFallbackTests {
    private let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// 60 pt gap to the right of `left`.
    private let farRight = CGRect(x: 1500, y: 0, width: 1920, height: 1080)

    private func index(_ x: CGFloat, _ y: CGFloat, _ screens: [CGRect]) -> Int? {
        ShelfLayout.screenIndex(containing: CGPoint(x: x, y: y), in: screens)
    }

    // MARK: Outer boundary with no neighbour

    @Test("the outer maxX, maxY and corner of the right-most screen resolve to it, wherever it sits in the list")
    func outerBoundaryResolvesToItsScreen() {
        for screens in [[left, farRight], [farRight, left]] {
            let rightIndex = screens.firstIndex(of: farRight)
            #expect(index(3420, 540, screens) == rightIndex)    // maxX
            #expect(index(2400, 1080, screens) == rightIndex)   // maxY
            #expect(index(3420, 1080, screens) == rightIndex)   // corner
        }
    }

    @Test("one pixel row past the outer boundary is on no screen")
    func pastOuterBoundaryIsNil() {
        #expect(index(3420.5, 540, [left, farRight]) == nil)
        #expect(index(2400, 1080.5, [left, farRight]) == nil)
        #expect(index(-0.5, 450, [left, farRight]) == nil)
        #expect(index(720, -0.5, [left, farRight]) == nil)
    }

    // MARK: Gap between non-adjacent screens

    @Test("a point inside a 60 pt gap resolves to nil, not to either neighbour")
    func gapResolvesToNil() {
        for screens in [[left, farRight], [farRight, left]] {
            #expect(index(1441, 450, screens) == nil)
            #expect(index(1470, 450, screens) == nil)
            #expect(index(1499.5, 450, screens) == nil)
        }
        // Also the diagonal gap: a screen up and to the right that touches neither axis range.
        let diagonal = CGRect(x: 1500, y: 1000, width: 1000, height: 800)
        #expect(index(1470, 950, [left, diagonal]) == nil)
    }

    @Test("the gap's two borders belong to the screens that own them: the left's last column and the right's first")
    func gapBordersBelongToTheirScreens() {
        #expect(index(1440, 450, [left, farRight]) == 0)
        #expect(index(1500, 450, [left, farRight]) == 1)
        #expect(index(1500, 450, [farRight, left]) == 0)
    }

    @Test("a point in a gap is `.away` for every placement, never an edge zone of a neighbour")
    func gapIsAwayThroughTheClassifier() {
        for placement in [ShelfPlacement.topCenter, .rightEdge, .leftEdge, .bottomEdge] {
            let region = ShelfPointerClassifier.region(
                at: CGPoint(x: 1470, y: 899), placement: placement, isVisible: false, panelFrame: .zero, screenFrame: nil,
                hoverMonitored: true, screens: [left, farRight], menuBarIcon: nil)
            #expect(region == .away)
        }
    }

    // MARK: Top row of a lower screen with a taller screen to the upper left

    @Test("top row of the lower screen with a taller screen above-left resolves to the lower screen, in either list order")
    func topRowOfLowerScreenBesideTallerNeighbour() {
        let lower = left  // 0..1440 x 0..900
        let taller = CGRect(x: -1920, y: 0, width: 1920, height: 1200)
        for screens in [[taller, lower], [lower, taller]] {
            let lowerIndex = screens.firstIndex(of: lower)
            let tallerIndex = screens.firstIndex(of: taller)
            #expect(index(720, 900, screens) == lowerIndex)    // the lower screen's physical top row
            #expect(index(1, 900, screens) == lowerIndex)
            #expect(index(1439, 900, screens) == lowerIndex)
            #expect(index(720, 899, screens) == lowerIndex)
            #expect(index(-960, 1200, screens) == tallerIndex)  // the taller screen's own top row
            #expect(index(-1, 1100, screens) == tallerIndex)
        }
    }

    @Test("top-centre zone: the lower screen's top row reveals on the lower screen, the taller one's on the taller")
    func topCentreZonesBesideTallerNeighbour() {
        let taller = CGRect(x: -1920, y: 0, width: 1920, height: 1200)
        for screens in [[taller, left], [left, taller]] {
            let lowerIndex = screens.firstIndex(of: left)!
            let tallerIndex = screens.firstIndex(of: taller)!
            #expect(ShelfLayout.screenIndex(of: CGPoint(x: 720, y: 900), placement: .topCenter, screens: screens) == lowerIndex)
            #expect(ShelfLayout.screenIndex(of: CGPoint(x: -960, y: 1200), placement: .topCenter, screens: screens) == tallerIndex)
            // Beside the lower screen's top zone, in the taller screen's interior: no zone.
            #expect(ShelfLayout.screenIndex(of: CGPoint(x: -960, y: 900), placement: .topCenter, screens: screens) == nil)
        }
    }

    @Test("a taller screen above and offset left: the seam row is the upper's where it covers, the lower's where it does not")
    func offsetUpperScreenSeam() {
        let lower = left
        let upper = CGRect(x: -720, y: 900, width: 1440, height: 900)  // covers x -720..720 above the lower screen
        for screens in [[upper, lower], [lower, upper]] {
            let lowerIndex = screens.firstIndex(of: lower)
            let upperIndex = screens.firstIndex(of: upper)
            #expect(index(360, 900, screens) == upperIndex)   // seam row under the upper screen: the upper's first row
            #expect(index(800, 900, screens) == lowerIndex)   // seam row where nothing is above: the lower's top row
            #expect(index(1439, 900, screens) == lowerIndex)
        }
    }
}
