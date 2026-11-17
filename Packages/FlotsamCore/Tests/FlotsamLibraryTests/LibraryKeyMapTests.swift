import FlotsamBase
import FlotsamPaste
import Testing
@testable import FlotsamLibrary

@Suite struct LibraryKeyMapTests {
    private let list = LibraryKeyMap.Context(searchIsEmpty: true, viewMode: .list)

    private func command(_ input: LibraryKeyInput, _ modifiers: ChordModifiers = [], in context: LibraryKeyMap.Context? = nil) -> LibraryCommand? {
        LibraryKeyMap.command(for: LibraryKeyStroke(input, modifiers), in: context ?? list)
    }

    @Test func selectionKeys() {
        #expect(command(.up) == .move(.up))
        #expect(command(.down) == .move(.down))
        #expect(command(.up, .command) == .jumpToFirst)
        #expect(command(.down, .command) == .jumpToLast)
        #expect(command(.up, .shift) == .extend(.up))
        #expect(command(.down, .shift) == .extend(.down))
    }

    @Test func pasteKeys() {
        #expect(command(.returnKey) == .paste(.paste))
        #expect(command(.returnKey, .option) == .paste(.plainText))
        #expect(command(.returnKey, .shift) == .paste(.copyOnly))
        for digit in 1...9 {
            #expect(command(.character(Character(String(digit))), .command) == .pasteRow(digit))
        }
        #expect(command(.character("0"), .command) == nil)
    }

    @Test func panelKeys() {
        #expect(command(.character("y"), .command) == .togglePreview)
        #expect(command(.escape) == .escape)
        #expect(command(.up, .option) == .previousFilter)
        #expect(command(.down, .option) == .nextFilter)
        #expect(command(.character("g"), .command) == .toggleViewMode)
        #expect(command(.character("r"), .command) == .revealInFinder)
        #expect(command(.character(","), .command) == .openSettings)
    }

    @Test func otherFeaturesKeys() {
        #expect(command(.character("p"), .command) == .external(.pin))
        #expect(command(.character("t"), .command) == .external(.tags))
        #expect(command(.character("n"), .command) == .external(.note))
        #expect(command(.character("e"), .command) == .external(.edit))
        #expect(command(.delete, .command) == .external(.delete))
        #expect(command(.character("s"), .command) == .external(.cycleSort))
        #expect(command(.character("u"), [.command, .shift]) == .external(.ungroup))
        #expect(command(.character("k"), .command) == .external(.shortcutAndTrigger))
    }

    @Test func spaceTogglesPreviewOnlyWithEmptySearch() {
        #expect(command(.space) == .togglePreview)
        #expect(command(.space, in: LibraryKeyMap.Context(searchIsEmpty: false, viewMode: .list)) == nil)
    }

    @Test func leftRightMoveOnlyInGrid() {
        #expect(command(.left) == nil)
        #expect(command(.right) == nil)
        let grid = LibraryKeyMap.Context(searchIsEmpty: true, viewMode: .grid)
        #expect(command(.left, in: grid) == .move(.left))
        #expect(command(.right, in: grid) == .move(.right))
    }

    @Test func printableKeysAndUnknownChordsPassThroughToSearch() {
        #expect(command(.character("a")) == nil)
        #expect(command(.character("a"), .shift) == nil)
        #expect(command(.character("z"), .command) == nil)
        #expect(command(.delete) == nil)
    }
}
