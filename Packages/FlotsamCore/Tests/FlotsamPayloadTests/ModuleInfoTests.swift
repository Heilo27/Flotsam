import Testing
@testable import FlotsamPayload
import FlotsamBase

@Suite struct PayloadModuleInfoTests {
    @Test func moduleDeclaresItsLogCategory() {
        #expect(PayloadModule.logCategory == .core)
    }
}
