import CoreGraphics
import FlotsamBase
import Testing
@testable import FlotsamLibrary

@Suite struct LibraryLayoutTests {
    @Test func opensCentredWithTopEdgeOneThirdDown() {
        let visible = CGRect(x: 0, y: 100, width: 1440, height: 900)
        let frame = LibraryLayout.frame(in: visible, size: PanelSize(width: 760, height: 480))
        #expect(frame.midX == visible.midX)
        #expect(frame.maxY == visible.maxY - visible.height / 3)
        #expect(frame.size == CGSize(width: 760, height: 480))
    }

    @Test func followsAScreenWithANonZeroOrigin() {
        let visible = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let frame = LibraryLayout.frame(in: visible, size: PanelSize(width: 760, height: 480))
        #expect(frame.midX == visible.midX)
        #expect(frame.minX >= visible.minX && frame.maxX <= visible.maxX)
    }

    @Test func sizeBelowTheMinimumIsRaised() {
        #expect(LibraryLayout.clamped(PanelSize(width: 100, height: 100)) == LibraryLayout.minimumSize)
        #expect(LibraryLayout.minimumSize == PanelSize(width: 560, height: 360))
    }

    @Test func sizeLargerThanTheScreenIsCutToIt() {
        let visible = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = LibraryLayout.frame(in: visible, size: PanelSize(width: 2000, height: 2000))
        #expect(visible.contains(frame))
    }
}
