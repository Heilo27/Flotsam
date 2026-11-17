import Testing
@testable import FlotsamCapture
import FlotsamBase

@Suite struct CaptureModuleInfoTests {
    @Test func moduleDeclaresItsLogCategory() {
        #expect(CaptureModule.logCategory == .capture)
    }
}
