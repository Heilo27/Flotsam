import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-508: the Library panel's key routing decision, formerly inline in the App target's LibraryPanelController.handle.
// Every expected value is a literal. The order (overlay, then key map, then the search field) is what the first suite pins:
// moving the overlay check after the key map turns every `.overlay` expectation below into a `.library` one.

@Suite struct LibraryKeyRoutingTests {
    private let list = LibraryKeyMap.Context(searchIsEmpty: true, viewMode: .list)
    private let listTyping = LibraryKeyMap.Context(searchIsEmpty: false, viewMode: .list)
    private let listSelecting = LibraryKeyMap.Context(searchIsEmpty: false, viewMode: .list, searchHasSelection: true)
    private let grid = LibraryKeyMap.Context(searchIsEmpty: true, viewMode: .grid)

    private func route(
        _ input: LibraryKeyInput, _ modifiers: ChordModifiers = [], overlay: Bool = false, in context: LibraryKeyMap.Context? = nil
    ) -> LibraryKeyRouting.Action {
        LibraryKeyRouting.route(LibraryKeyStroke(input, modifiers), overlayIsOpen: overlay, context: context ?? list)
    }

    // MARK: Overlay first

    @Test func openOverlayOwnsEveryKeyTheKeyMapWouldHaveTaken() {
        #expect(route(.escape, overlay: true) == .overlay)
        #expect(route(.returnKey, overlay: true) == .overlay)
        #expect(route(.returnKey, .command, overlay: true) == .overlay)
        #expect(route(.returnKey, .option, overlay: true) == .overlay)
        #expect(route(.returnKey, .shift, overlay: true) == .overlay)
        #expect(route(.character("c"), .command, overlay: true) == .overlay)
        #expect(route(.character("c"), .command, overlay: true, in: listSelecting) == .overlay)
        #expect(route(.space, overlay: true) == .overlay)
        #expect(route(.up, overlay: true) == .overlay)
        #expect(route(.character("1"), .command, overlay: true) == .overlay)
    }

    @Test func openOverlayOwnsKeysTheKeyMapDoesNotKnowToo() {
        #expect(route(.character("a"), overlay: true) == .overlay)
        #expect(route(.space, overlay: true, in: listTyping) == .overlay)
        #expect(route(.left, overlay: true, in: list) == .overlay)
    }

    @Test func overlayClosedIsTheKeyMapAgain() {
        #expect(route(.escape, overlay: false) == .library(.escape))
        #expect(route(.character("c"), .command, overlay: false) == .library(.paste(.copyOnly)))
    }

    // MARK: Command-C (FR-003-08)

    @Test func commandCCopiesTheRowCopyOnlyWhenTheFieldHasNoSelection() {
        #expect(route(.character("c"), .command) == .library(.paste(.copyOnly)))
        #expect(route(.character("c"), .command, in: listTyping) == .library(.paste(.copyOnly)))
    }

    @Test func commandCGoesToTheFieldWhenItHoldsASelection() {
        #expect(route(.character("c"), .command, in: listSelecting) == .passToField)
    }

    @Test func theSelectionExceptionIsCommandCOnly() {
        #expect(route(.returnKey, in: listSelecting) == .library(.paste(.paste)))
        #expect(route(.character("y"), .command, in: listSelecting) == .library(.togglePreview))
        #expect(route(.character("c"), [.command, .shift], in: listSelecting) == .passToField)
        #expect(route(.character("c"), [.command, .option], in: listSelecting) == .passToField)
    }

    // MARK: Return family

    @Test func returnPastesOptionReturnPastesPlainTextShiftReturnCopiesOnly() {
        #expect(route(.returnKey) == .library(.paste(.paste)))
        #expect(route(.returnKey, .option) == .library(.paste(.plainText)))
        #expect(route(.returnKey, .shift) == .library(.paste(.copyOnly)))
    }

    @Test func returnWithOtherModifiersIsNotTheLibrarys() {
        #expect(route(.returnKey, .command) == .passToField)
        #expect(route(.returnKey, [.option, .shift]) == .passToField)
    }

    @Test func returnRoutesTheSameWhateverTheSearchState() {
        for context in [list, listTyping, listSelecting, grid] {
            #expect(route(.returnKey, in: context) == .library(.paste(.paste)))
            #expect(route(.returnKey, .option, in: context) == .library(.paste(.plainText)))
            #expect(route(.returnKey, .shift, in: context) == .library(.paste(.copyOnly)))
        }
    }

    // MARK: Esc and Space

    @Test func escapeIsTheLadderCommandInEveryState() {
        for context in [list, listTyping, listSelecting, grid] {
            #expect(route(.escape, in: context) == .library(.escape))
        }
    }

    @Test func spaceTogglesPreviewOnlyWhileTheSearchFieldIsEmpty() {
        #expect(route(.space) == .library(.togglePreview))
        #expect(route(.space, in: grid) == .library(.togglePreview))
        #expect(route(.space, in: listTyping) == .passToField)
        #expect(route(.space, in: listSelecting) == .passToField)
    }

    @Test func spaceWithAModifierIsNotThePreviewKey() {
        #expect(route(.space, .command) == .passToField)
        #expect(route(.space, .shift) == .passToField)
    }

    // MARK: Pass-through

    @Test func leftAndRightMoveOnlyInAGrid() {
        #expect(route(.left, in: grid) == .library(.move(.left)))
        #expect(route(.right, in: grid) == .library(.move(.right)))
        #expect(route(.left) == .passToField)
        #expect(route(.right) == .passToField)
    }

    @Test func unmappedKeysGoToTheField() {
        #expect(route(.character("a")) == .passToField)
        #expect(route(.character("0"), .command) == .passToField)
        #expect(route(.up, [.command, .option]) == .passToField)
    }

    @Test func otherMappedKeysBecomeLibraryCommands() {
        #expect(route(.up) == .library(.move(.up)))
        #expect(route(.down, .command) == .library(.jumpToLast))
        #expect(route(.character("5"), .command) == .library(.pasteRow(5)))
        #expect(route(.character("k"), .command) == .library(.external(.shortcutAndTrigger)))
    }

    // MARK: Trust is not a routing input

    @MainActor
    @Test func routingIsTheSameWithAccessibilityTrustedOrNot() {
        // The context comes from the model; the model's trust answer must not change what a key resolves to.
        let strokes: [(LibraryKeyInput, ChordModifiers)] = [
            (.returnKey, []), (.returnKey, .option), (.returnKey, .shift), (.character("c"), .command), (.escape, []), (.space, []),
        ]
        let trusted = Harness(rows: Harness.rows(2), accessibility: true)
        let untrusted = Harness(rows: Harness.rows(2), accessibility: false)
        for (input, modifiers) in strokes {
            let stroke = LibraryKeyStroke(input, modifiers)
            let a = LibraryKeyRouting.route(stroke, overlayIsOpen: false, context: trusted.model.keyContext())
            let b = LibraryKeyRouting.route(stroke, overlayIsOpen: false, context: untrusted.model.keyContext())
            #expect(a == b)
        }
    }
}

// The routed command is then dispatched by the controller with `model.perform`. These suites run that second half over the
// fakes the paste tests use, with Accessibility off and on, for the keys whose mode the untrusted gate acts on.
@MainActor
@Suite struct LibraryKeyDispatchTests {
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    private func opened(accessibility: Bool) async -> Harness {
        let harness = Harness(rows: Harness.rows(3), accessibility: accessibility)
        await harness.model.open(target: target)
        return harness
    }

    /// The controller's dispatch for an overlay-closed panel: route, then perform a library command.
    @discardableResult
    private func dispatch(_ harness: Harness, _ input: LibraryKeyInput, _ modifiers: ChordModifiers = [], selection: Bool = false) async -> Bool {
        let action = LibraryKeyRouting.route(
            LibraryKeyStroke(input, modifiers), overlayIsOpen: false, context: harness.model.keyContext(searchHasSelection: selection))
        guard case .library(let command) = action else { return false }
        harness.model.perform(command)
        await harness.model.pasteTask?.value
        return true
    }

    @Test(arguments: [true, false])
    func returnFamilyAsksThePasterForTheModeTheKeyNames(accessibility: Bool) async {
        let h = await opened(accessibility: accessibility)
        let id = h.model.visibleRows[0].id
        await dispatch(h, .returnKey)
        await dispatch(h, .returnKey, .option)
        await dispatch(h, .returnKey, .shift)
        #expect(h.paster.calls.map(\.mode) == [.paste, .plainText, .copyOnly])
        #expect(h.paster.calls.map(\.itemId) == [id, id, id])
    }

    @Test(arguments: [true, false])
    func commandCIsCopyOnlyOfTheSelectedRowAndNothingWithAFieldSelection(accessibility: Bool) async {
        let h = await opened(accessibility: accessibility)
        let id = h.model.visibleRows[0].id
        let consumedWithSelection = await dispatch(h, .character("c"), .command, selection: true)
        #expect(consumedWithSelection == false)
        #expect(h.paster.calls.isEmpty)
        let consumed = await dispatch(h, .character("c"), .command)
        #expect(consumed)
        #expect(h.paster.calls == [FakePaster.Call(itemId: id, mode: .copyOnly, target: target)])
    }

    @Test func untrustedCopyOnlyOutcomeOfAReturnPasteIsReportedAsSetPrm001() async {
        // The fake paster stands in for PasteService: it answers what the real one answers when Accessibility is off.
        let h = await opened(accessibility: false)
        h.paster.result = .success(.copiedAccessibilityDenied)
        await dispatch(h, .returnKey)
        #expect(h.reported.errors.count == 1)
        #expect(h.reported.errors.first?.code == .setPrm001)
    }

    @Test func escapeKeyRunsTheLadderOnTheModel() async {
        let h = await opened(accessibility: false)
        h.model.setSearchText("abc")
        await dispatch(h, .escape)
        #expect(h.model.searchText == "")
        #expect(h.host.hideCount == 0)
        await dispatch(h, .escape)
        #expect(h.host.hideCount == 1)
    }

    @Test func spaceTogglesThePreviewWhileTheFieldIsEmptyAndLeavesItAloneWhenTyping() async {
        let h = await opened(accessibility: false)
        #expect(h.model.isPreviewOpen == false)
        let consumed = await dispatch(h, .space)
        #expect(consumed)
        #expect(h.model.isPreviewOpen)
        h.model.setSearchText("a")
        let typing = await dispatch(h, .space)
        #expect(typing == false)
        #expect(h.model.isPreviewOpen)
    }
}
