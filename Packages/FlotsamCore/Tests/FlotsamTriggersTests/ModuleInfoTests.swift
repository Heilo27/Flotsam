import Testing
@testable import FlotsamTriggers
import FlotsamBase

@Suite struct TriggersModuleInfoTests {
    @Test func moduleDeclaresItsLogCategory() {
        #expect(TriggersModule.logCategory == .triggers)
    }
}
