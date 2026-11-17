import Testing
@testable import FlotsamShortcuts
import FlotsamBase

@Suite struct ShortcutsModuleInfoTests {
    @Test func moduleDeclaresItsLogCategory() {
        #expect(ShortcutsModule.logCategory == .triggers)
    }
}
