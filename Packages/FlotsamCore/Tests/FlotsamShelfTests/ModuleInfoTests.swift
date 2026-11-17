import Testing
@testable import FlotsamShelf
import FlotsamBase

@Suite struct ShelfModuleInfoTests {
    @Test func moduleDeclaresItsLogCategory() {
        #expect(ShelfModule.logCategory == .shelf)
    }
}
