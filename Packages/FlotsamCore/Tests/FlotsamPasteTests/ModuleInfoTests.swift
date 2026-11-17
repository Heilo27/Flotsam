import Testing
@testable import FlotsamPaste
import FlotsamBase

@Suite struct PasteModuleInfoTests {
    @Test func moduleDeclaresItsLogCategory() {
        #expect(PasteModule.logCategory == .library)
    }
}
