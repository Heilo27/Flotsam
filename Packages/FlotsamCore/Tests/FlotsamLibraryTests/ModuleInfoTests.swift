import Testing
@testable import FlotsamLibrary
import FlotsamBase

@Suite struct LibraryModuleInfoTests {
    @Test func moduleDeclaresItsLogCategory() {
        #expect(LibraryModule.logCategory == .library)
    }
}
