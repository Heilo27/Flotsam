import FlotsamBase
import Testing
@testable import FlotsamShelf

@Suite struct ShelfKeyMapTests {
    @Test func oc6050_arrowsMoveReturnPastesAndEscapeHidesInASticky() {
        func command(_ input: KeyInput, _ modifiers: ChordModifiers = []) -> ShelfCommand? {
            ShelfKeyMap.command(for: KeyStroke(input, modifiers), isSticky: true)
        }
        #expect(command(.up) == .move(.previous))
        #expect(command(.left) == .move(.previous))
        #expect(command(.down) == .move(.next))
        #expect(command(.right) == .move(.next))
        #expect(command(.returnKey) == .paste(.paste))
        #expect(command(.returnKey, .option) == .paste(.plainText))
        #expect(command(.returnKey, .shift) == .paste(.copyOnly))
        #expect(command(.character("c"), .command) == .paste(.copyOnly))
        #expect(command(.escape) == .hide)
        #expect(command(.space) == nil)
        #expect(command(.character("c")) == nil)
    }

    @Test func oc6056_aTransientShelfHandlesNoKey() {
        for input in [KeyInput.up, .down, .left, .right, .returnKey, .escape, .space] {
            #expect(ShelfKeyMap.command(for: KeyStroke(input), isSticky: false) == nil)
        }
    }
}
