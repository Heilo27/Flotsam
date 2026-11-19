import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-508 (Worf, blind QA). The extraction must leave the Library key routing exactly as the old inline controller
// decided it: overlay first, then the key map, then the search field. Every expected value is a literal read from
// docs/DESIGN.md section 6 and FR-003-08, never from LibraryKeyMap. The collaborators of the secure suite are the
// shipping ones (see SecureContractRig); only the Keychain, owner check, pasteboard and key poster are fakes.

private let list = LibraryKeyMap.Context(searchIsEmpty: true, viewMode: .list)
private let typing = LibraryKeyMap.Context(searchIsEmpty: false, viewMode: .list)
private let selecting = LibraryKeyMap.Context(searchIsEmpty: false, viewMode: .grid, searchHasSelection: true)

@Suite struct Worf508KeyRoutingAdversarialTests {
    private func route(
        _ input: LibraryKeyInput, _ modifiers: ChordModifiers = [], overlay: Bool = false, in context: LibraryKeyMap.Context = list
    ) -> LibraryKeyRouting.Action {
        LibraryKeyRouting.route(LibraryKeyStroke(input, modifiers), overlayIsOpen: overlay, context: context)
    }

    // The whole DESIGN section 6 table, one literal per row.
    private static let designTable: [(LibraryKeyInput, ChordModifiers, LibraryCommand)] = [
        (.up, [], .move(.up)), (.down, [], .move(.down)),
        (.up, .command, .jumpToFirst), (.down, .command, .jumpToLast),
        (.up, .shift, .extend(.up)), (.down, .shift, .extend(.down)),
        (.returnKey, [], .paste(.paste)), (.returnKey, .option, .paste(.plainText)), (.returnKey, .shift, .paste(.copyOnly)),
        (.character("c"), .command, .paste(.copyOnly)),
        (.character("1"), .command, .pasteRow(1)), (.character("2"), .command, .pasteRow(2)), (.character("3"), .command, .pasteRow(3)),
        (.character("4"), .command, .pasteRow(4)), (.character("5"), .command, .pasteRow(5)), (.character("6"), .command, .pasteRow(6)),
        (.character("7"), .command, .pasteRow(7)), (.character("8"), .command, .pasteRow(8)), (.character("9"), .command, .pasteRow(9)),
        (.space, [], .togglePreview), (.character("y"), .command, .togglePreview),
        (.escape, [], .escape),
        (.up, .option, .previousFilter), (.down, .option, .nextFilter),
        (.character("g"), .command, .toggleViewMode), (.character("r"), .command, .revealInFinder),
        (.character("p"), .command, .external(.pin)), (.character("t"), .command, .external(.tags)),
        (.character("n"), .command, .external(.note)), (.character("e"), .command, .external(.edit)),
        (.delete, .command, .external(.delete)), (.character("s"), .command, .external(.cycleSort)),
        (.character("u"), [.command, .shift], .external(.ungroup)), (.character("k"), .command, .external(.shortcutAndTrigger)),
        (.character(","), .command, .openSettings),
    ]

    // given the overlay is closed, when each key of the section 6 table is routed, then it is the Library's command;
    // given the overlay is open, then every one of them is the overlay's. Red under: an overlay check moved after the
    // key map, a table row dropped, or a command remapped by the router.
    @Test func everyDesignTableKeyIsTheLibrarysWhenClosedAndTheOverlaysWhenOpen() {
        #expect(Self.designTable.count == 35)
        for (input, modifiers, command) in Self.designTable {
            #expect(route(input, modifiers) == .library(command), "closed: \(input) \(modifiers)")
            #expect(route(input, modifiers, overlay: true) == .overlay, "open: \(input) \(modifiers)")
        }
    }

    // given the standard text-editing keys that FR-003-08 / FR-008-19 leave out of the table, when routed, then they
    // pass to the field (the main menu acts on it); with an overlay open they are the overlay's.
    // Red under: a router that claims any of them for the Library.
    @Test func standardTextEditingKeysAreNeverTheLibrarys() {
        let keys: [(LibraryKeyInput, ChordModifiers)] = [
            (.character("a"), .command), (.character("v"), .command), (.character("x"), .command),
            (.character("z"), .command), (.character("z"), [.command, .shift]),
        ]
        for (input, modifiers) in keys {
            #expect(route(input, modifiers) == .passToField)
            #expect(route(input, modifiers, in: selecting) == .passToField)
            #expect(route(input, modifiers, overlay: true) == .overlay)
        }
    }

    // given a text selection in the search field, when Command-C is routed in either view mode, with or without typed
    // text, then it is the field's; and the exception is for exactly that chord (Shift-Return, Command-Y, Return stay).
    // Red under: dropping the selection exception, or applying it to every key.
    @Test func selectionExceptionHoldsInEveryContextAndOnlyForCommandC() {
        for mode in [LibraryViewMode.list, .grid] {
            for empty in [true, false] {
                let withSelection = LibraryKeyMap.Context(searchIsEmpty: empty, viewMode: mode, searchHasSelection: true)
                let without = LibraryKeyMap.Context(searchIsEmpty: empty, viewMode: mode, searchHasSelection: false)
                #expect(route(.character("c"), .command, in: withSelection) == .passToField)
                #expect(route(.character("c"), .command, in: without) == .library(.paste(.copyOnly)))
                #expect(route(.returnKey, .shift, in: withSelection) == .library(.paste(.copyOnly)))
                #expect(route(.character("y"), .command, in: withSelection) == .library(.togglePreview))
                #expect(route(.escape, in: withSelection) == .library(.escape))
            }
        }
    }

    // given the overlay is open and the field holds a selection, when Command-C is routed, then the overlay owns it:
    // it is never the Library's row copy (FR-003-08: in the Organize overlays Command-C is always the text copy).
    @Test func overlayOpenCommandCIsOverlayWhateverTheSelection() {
        #expect(route(.character("c"), .command, overlay: true, in: list) == .overlay)
        #expect(route(.character("c"), .command, overlay: true, in: selecting) == .overlay)
    }

    // given the key map says "no" the router says pass-through and never anything the Library would consume.
    // Red under: swapping .passToField for .library in the router.
    @Test func everyUnownedKeyIsPassToFieldNotALibraryCommand() {
        let unowned: [(LibraryKeyInput, ChordModifiers)] = [
            (.character("a"), []), (.character("c"), []), (.character("c"), [.command, .shift]), (.character("0"), .command),
            (.left, []), (.right, []), (.space, .command), (.returnKey, .command), (.returnKey, [.option, .shift]),
            (.up, [.command, .shift]), (.delete, []),
        ]
        for (input, modifiers) in unowned {
            #expect(route(input, modifiers) == .passToField, "\(input) \(modifiers)")
        }
        #expect(route(.space, in: typing) == .passToField)
    }
}

// The model's own entry point `handle` now delegates to the router; its Bool is what the controller used to return as
// "nil" (consumed) versus the event (passed on).
@MainActor
@Suite struct Worf508HandleContractTests {
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    // given an open panel with a typed query, when handle is called, then true means "consumed and acted", false means
    // "left for the field and nothing ran". Red under: handle returning true for an unowned key, or running a command
    // while returning false.
    @Test func handleReturnsTrueExactlyWhenItRanACommand() async {
        let h = Harness(rows: Harness.rows(3))
        await h.model.open(target: target)
        h.model.setSearchText("ab")
        let rowsBefore = h.model.visibleRows.map(\.id)

        #expect(h.model.handle(LibraryKeyStroke(.character("a"))) == false)
        #expect(h.model.handle(LibraryKeyStroke(.space)) == false)
        #expect(h.model.isPreviewOpen == false)
        #expect(h.paster.calls.isEmpty)
        #expect(h.model.searchText == "ab")

        #expect(h.model.handle(LibraryKeyStroke(.character("y"), .command)))
        #expect(h.model.isPreviewOpen)
        #expect(h.model.visibleRows.map(\.id) == rowsBefore)
    }

    // given the search field has a selection, when Command-C reaches handle, then false and no copy; without it, true
    // and exactly one copy-only paste of the selected row, not a neighbour. Red under: the selection flag dropped in
    // keyContext or in handle.
    @Test func commandCSelectionFlagIsForwardedByHandle() async {
        let h = Harness(rows: Harness.rows(3))
        await h.model.open(target: target)
        let selected = h.model.visibleRows[0].id
        let neighbour = h.model.visibleRows[1].id

        let withSelection = h.model.handle(LibraryKeyStroke(.character("c"), .command), searchHasSelection: true)
        #expect(withSelection == false)
        #expect(h.paster.calls.isEmpty)

        let without = h.model.handle(LibraryKeyStroke(.character("c"), .command))
        await h.model.pasteTask?.value
        #expect(without)
        #expect(h.paster.calls.count == 1)
        #expect(h.paster.calls.first?.itemId == selected)
        #expect(h.paster.calls.first?.itemId != neighbour)
        #expect(h.paster.calls.first?.mode == .copyOnly)
    }

    // given the query is empty versus typed, when keyContext is read, then it reports exactly that and the selection
    // flag as passed (literals). Red under: inverting searchIsEmpty, dropping the flag, or reading the wrong view mode.
    @Test func keyContextReportsTheModelsSearchAndViewMode() async {
        let h = Harness(rows: Harness.rows(2))
        await h.model.open(target: target)
        #expect(h.model.keyContext() == LibraryKeyMap.Context(searchIsEmpty: true, viewMode: .list, searchHasSelection: false))
        h.model.setSearchText("x")
        #expect(h.model.keyContext(searchHasSelection: true)
            == LibraryKeyMap.Context(searchIsEmpty: false, viewMode: .list, searchHasSelection: true))
        h.model.toggleViewMode()
        #expect(h.model.keyContext() == LibraryKeyMap.Context(searchIsEmpty: false, viewMode: .grid, searchHasSelection: false))
    }

    // given an empty library, when Return is handled, then it is still consumed (the Library owns the key) but nothing
    // is pasted (boundary: no rows).
    @Test func returnOnAnEmptyPanelIsConsumedAndPastesNothing() async {
        let h = Harness(rows: [])
        await h.model.open(target: target)
        let consumed = h.model.handle(LibraryKeyStroke(.returnKey))
        #expect(consumed)
        #expect(h.model.pasteTask == nil)
        #expect(h.paster.calls.isEmpty)
    }
}

// Command-C on secure rows through the controller's exact dispatch shape (route, then perform), with the overlay open
// and closed. The shipping PasteService, SecureClipAccess and database are under test.
@MainActor
@Suite struct Worf508SecureCommandCRoutingTests {
    private func dispatch(
        _ rig: SecureContractRig, overlay: Bool, selection: Bool = false
    ) async -> LibraryKeyRouting.Action {
        let action = LibraryKeyRouting.route(
            LibraryKeyStroke(.character("c"), .command), overlayIsOpen: overlay,
            context: rig.model.keyContext(searchHasSelection: selection))
        if case .library(let command) = action {
            rig.model.perform(command)
            await rig.model.pasteTask?.value
            await rig.model.settled()
        }
        return action
    }

    // given a secure row selected, when Command-C is routed with an overlay open, with a search selection, and then
    // plainly, then the first two do nothing at all (no prompt, no decrypt, no write) and only the third prompts once,
    // decrypts after the prompt and writes the plain text once. Red under: overlay ignored, selection exception dropped,
    // or the gate bypassed.
    @Test func secureRowCommandCIsAuthGatedAndInertWhenOverlayOrSelectionOwnsIt() async throws {
        let rig = try await SecureContractRig()
        let secure = try await rig.addSecure()
        _ = try await rig.addPlain("plain-text", secondsAgo: 10)
        await rig.open()
        rig.select(secure)
        let before = rig.pasteboard.written.count

        let overlayAction = await dispatch(rig, overlay: true)
        #expect(overlayAction == .overlay)
        let selectionAction = await dispatch(rig, overlay: false, selection: true)
        #expect(selectionAction == .passToField)
        #expect(rig.log.events == [])
        #expect(rig.pasteboard.written.count == before)
        #expect(rig.host.hideCount == 0)

        let plainAction = await dispatch(rig, overlay: false)
        #expect(plainAction == .library(.paste(.copyOnly)))
        #expect(rig.log.events == ["auth", "open"])
        #expect(rig.pasteboard.written.count == before + 1)
        #expect(rig.lastText == "hunter2-secret")
        #expect(rig.keys.posts == 0)
        rig.cleanUp()
    }

    // given a cancelled owner check, when Command-C is routed plainly, then nothing is written and LIB-OS-002 shows once.
    @Test func cancelledPromptThroughTheRouterWritesNothing() async throws {
        let rig = try await SecureContractRig(answers: [SecureContractAuthenticator.cancelled])
        let secure = try await rig.addSecure()
        await rig.open()
        rig.select(secure)
        let before = rig.pasteboard.written.count
        _ = await dispatch(rig, overlay: false)
        #expect(rig.log.events == ["auth"])
        #expect(rig.pasteboard.written.count == before)
        #expect(rig.reported.errors.map(\.code) == [.libOs002])
        rig.cleanUp()
    }
}
