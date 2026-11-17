import Testing
@testable import FlotsamScreenshots
import FlotsamBase

@Suite struct ScreenshotsModuleInfoTests {
    @Test func moduleDeclaresItsLogCategory() {
        #expect(ScreenshotsModule.logCategory == .screenshots)
    }
}
