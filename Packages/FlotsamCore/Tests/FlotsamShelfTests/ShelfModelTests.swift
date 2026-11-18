import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf

@MainActor
@Suite struct ShelfModelTests {
    private func rows(_ numbers: Range<Int>, pinned: Bool = false) -> [ItemRow] {
        numbers.map { makeShelfRow($0, pinned: pinned) }
    }

    private func texts(_ section: ShelfSection) -> [String?] { section.cards.map(\.text) }

    // MARK: FR-006-06 contents

    @Test func oc6041_onlyPinnedItemsShowOnlyThePinnedSection() async {
        let rig = ShelfRig(rows: rows(1..<4, pinned: true))
        await rig.openSticky()
        let sections = rig.model.sections()
        #expect(sections.map(\.kind) == [.pinned])
        #expect(sections.first?.cards.map(\.id) == [shelfID(1), shelfID(2), shelfID(3)])
        #expect(!rig.model.isEmpty)
    }

    @Test func oc6041_onlyUnpinnedItemsShowOnlyTheRecentSection() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        let sections = rig.model.sections()
        #expect(sections.map(\.kind) == [.recent])
        #expect(sections.first?.cards.map(\.id) == [shelfID(1), shelfID(2), shelfID(3)])
    }

    @Test func oc6041_pinnedItemsAreNotRepeatedInRecentAndNoItemsIsEmpty() async {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2, pinned: true), makeShelfRow(3)])
        await rig.openSticky()
        let sections = rig.model.sections()
        #expect(sections.map(\.kind) == [.pinned, .recent])
        #expect(sections[0].cards.map(\.id) == [shelfID(2)])
        #expect(sections[1].cards.map(\.id) == [shelfID(1), shelfID(3)])

        let empty = ShelfRig(rows: [])
        await empty.openSticky()
        #expect(empty.model.sections().isEmpty)
        #expect(empty.model.isEmpty)
    }

    @Test func oc6041_eachSectionHoldsAtMostTwentyCards() async {
        let all = rows(1..<31, pinned: true) + rows(31..<71)
        let rig = ShelfRig(rows: all)
        await rig.openSticky()
        let sections = rig.model.sections()
        #expect(sections[0].cards.count == 20)
        #expect(sections[1].cards.count == 20)
        #expect(sections[1].cards.first?.id == shelfID(31))
    }

    @Test func oc6042_theShelfAsksForPinnedAndUnfilteredRecentInCopyOrderWhateverTheLibraryShows() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        let queries = rig.source.queries
        #expect(queries.count == 2)
        #expect(queries.contains(LibraryQuery(filter: .pinned, text: "", sort: .recent, page: 0)))
        #expect(queries.contains(LibraryQuery(filter: .all, text: "", sort: .recent, page: 0)))
    }

    @Test func oc6043_pinningARecentCardMovesItToPinnedWithoutWaitingForAnEvent() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.perform(.togglePin, on: shelfID(2))
        await rig.model.settled()
        let sections = rig.model.sections()
        #expect(sections.map(\.kind) == [.pinned, .recent])
        #expect(sections[0].cards.map(\.id) == [shelfID(2)])
        #expect(sections[1].cards.map(\.id) == [shelfID(1), shelfID(3)])
    }

    @Test func oc6043_aStoredChangeRefreshesTheVisibleShelf() async {
        let rig = ShelfRig(rows: rows(1..<3))
        await rig.openSticky()
        rig.source.rows = rows(1..<4)
        rig.bus.publish(.itemsChanged)
        await settle(rig) { rig.model.orderedRows.count == 3 }
        #expect(rig.model.orderedRows.count == 3)
    }

    @Test func oc6043_aHiddenShelfStopsListeningToStoredChanges() async {
        let rig = ShelfRig(rows: rows(1..<3))
        await rig.openSticky()
        rig.model.didHide()
        let before = rig.source.queries.count
        rig.bus.publish(.itemsChanged)
        try? await Task.sleep(for: .milliseconds(100))
        await rig.model.settled()
        #expect(rig.source.queries.count == before)
    }

    @Test func oc6044_captureIsFlushedBeforeTheListIsReadSoAJustCopiedItemLeadsRecent() async {
        let rig = ShelfRig(rows: rows(2..<4)) { _ in }
        rig.probe.onCapture = { [source = rig.source] in source.rows = [makeShelfRow(1, primary: "just-now-1")] + source.rows }
        await rig.openSticky()
        #expect(rig.log.entries.first == "captureNow")
        #expect(rig.model.sections().first?.cards.first?.id == shelfID(1))
        #expect(rig.model.sections().first?.cards.first?.text == "just-now-1")
    }

    @Test func cardTextComesFromTheDetailsPortElseThePrimaryLine() async {
        let details = FakeShelfDetails(texts: [shelfID(1): "line one\nline two\nline three\nline four"])
        let rig = ShelfRig(rows: [makeShelfRow(1, primary: "line one"), makeShelfRow(2, primary: "fallback")], details: details)
        await rig.openSticky()
        let cards = rig.model.sections()[0].cards
        #expect(cards[0].text == "line one\nline two\nline three")
        #expect(cards[1].text == "fallback")
    }

    // The Missing rule itself (moved, deleted, partial, empty, and agreement with the Library) is in
    // ShelfMissingTests. These pin only that the card shows the row's flag, and nothing else.
    @Test func cardShowsTheRowsMissingFlagAndNoOther() async {
        let rig = ShelfRig(rows: [
            makeShelfRow(1, kind: .file, missing: true), makeShelfRow(2, kind: .bundle, memberCount: 2),
            makeShelfRow(3, kind: .folder, missing: true),
        ])
        await rig.openSticky()
        let cards = rig.model.sections()[0].cards
        #expect(cards.map(\.isMissing) == [true, false, true])
    }

    @Test func aFailedTextReadIsReportedAndTheCardsFallBackToThePrimaryLine() async {
        let failure = FlotsamError(.stoDb004, "Database read failed")
        let details = FakeShelfDetails(texts: [shelfID(1): "full text"], failure: failure)
        let rig = ShelfRig(rows: [makeShelfRow(1, primary: "primary one")], details: details)
        await rig.openSticky()
        #expect(rig.probe.reports.map(\.code) == [.stoDb004])
        #expect(rig.model.sections()[0].cards[0].text == "primary one")
        #expect(rig.model.loadState == .loaded)
    }

    // MARK: FR-006-08 keyboard

    @Test func oc6050_downDownReturnPastesTheThirdCardIntoTheRecordedTarget() async {
        let rig = ShelfRig(rows: rows(1..<5))
        await rig.openSticky()
        #expect(rig.model.selection == [shelfID(1)])
        #expect(rig.model.handle(KeyStroke(.down)))
        #expect(rig.model.handle(KeyStroke(.down)))
        #expect(rig.model.handle(KeyStroke(.returnKey)))
        await rig.model.settled()
        #expect(rig.paster.calls == [.init(itemId: shelfID(3), mode: .paste, target: textEdit)])
        #expect(rig.host.hideCount == 1)
    }

    @Test func oc6050_upAndLeftGoBackRightGoesOnAndTheEndsStop() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.handle(KeyStroke(.up))
        #expect(rig.model.cursorID == shelfID(1))
        rig.model.handle(KeyStroke(.right))
        rig.model.handle(KeyStroke(.right))
        rig.model.handle(KeyStroke(.right))
        #expect(rig.model.cursorID == shelfID(3))
        #expect(rig.model.selection == [shelfID(3)])
        rig.model.handle(KeyStroke(.left))
        #expect(rig.model.cursorID == shelfID(2))
    }

    @Test func oc6050_theArrowsWalkPinnedThenRecent() async {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2, pinned: true), makeShelfRow(3)])
        await rig.openSticky()
        #expect(rig.model.cursorID == shelfID(2))
        rig.model.handle(KeyStroke(.down))
        #expect(rig.model.cursorID == shelfID(1))
    }

    @Test func oc6051_shiftReturnCopiesOnlyTheSelectedCard() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(2))
        rig.model.handle(KeyStroke(.returnKey, .shift))
        await rig.model.settled()
        #expect(rig.paster.calls == [.init(itemId: shelfID(2), mode: .copyOnly, target: textEdit)])
    }

    @Test func pasteKeysNeedExactlyOneSelectedCard() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(1))
        rig.model.click(shelfID(2), modifiers: .command)
        rig.model.handle(KeyStroke(.returnKey))
        rig.model.handle(KeyStroke(.character("c"), .command))
        await rig.model.settled()
        #expect(rig.paster.calls.isEmpty)
    }

    @Test func oc6052_escapeHidesWithoutPastingOrCopying() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        #expect(rig.model.handle(KeyStroke(.escape)))
        await rig.model.settled()
        #expect(rig.host.hideCount == 1)
        #expect(rig.paster.calls.isEmpty)
        #expect(!rig.model.isOpen)
    }

    @Test func oc6053_optionReturnPastesAsPlainText() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.handle(KeyStroke(.returnKey, .option))
        await rig.model.settled()
        #expect(rig.paster.calls == [.init(itemId: shelfID(1), mode: .plainText, target: textEdit)])
    }

    @Test func oc6054_commandCCopiesOnlyTheSelectedCard() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(3))
        #expect(rig.model.handle(KeyStroke(.character("c"), .command)))
        await rig.model.settled()
        #expect(rig.paster.calls == [.init(itemId: shelfID(3), mode: .copyOnly, target: textEdit)])
    }

    @Test func oc6055_spaceIsNotUsedAndChangesNothing() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(2))
        let sectionsBefore = rig.model.sections()
        #expect(!rig.model.handle(KeyStroke(.space)))
        await rig.model.settled()
        #expect(rig.paster.calls.isEmpty)
        #expect(rig.host.hideCount == 0)
        #expect(rig.model.selection == [shelfID(2)])
        #expect(rig.model.sections() == sectionsBefore)
        #expect(rig.model.isOpen)
    }

    @Test func aShelfThatIsNotOpenTakesNoKeys() async {
        let rig = ShelfRig(rows: rows(1..<4))
        #expect(!rig.model.handle(KeyStroke(.returnKey)))
        await rig.openSticky()
        rig.model.didHide()
        #expect(!rig.model.handle(KeyStroke(.returnKey)))
        #expect(!rig.model.handle(KeyStroke(.escape)))
        await rig.model.settled()
        #expect(rig.paster.calls.isEmpty)
        #expect(rig.host.hideCount == 0)
    }

    @Test func oc6056_aTransientShelfTakesNoKeys() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.model.open(target: textEdit, sticky: false)
        #expect(!rig.model.handle(KeyStroke(.down)))
        #expect(!rig.model.handle(KeyStroke(.returnKey)))
        await rig.model.settled()
        #expect(rig.paster.calls.isEmpty)
        #expect(rig.model.cursorID == shelfID(1))
    }

    @Test func oc6057_accessibilityOffReportsSetPrm001AndKeepsTheItemOnTheClipboard() async {
        let rig = ShelfRig(rows: rows(1..<3))
        rig.paster.result = .success(.copiedAccessibilityDenied)
        await rig.openSticky()
        rig.model.handle(KeyStroke(.returnKey))
        await rig.model.settled()
        #expect(rig.paster.calls == [.init(itemId: shelfID(1), mode: .paste, target: textEdit)])
        #expect(rig.probe.reports.map(\.code) == [.setPrm001])
    }

    @Test func aPasteFailureIsReportedAndAVanishedItemReloadsTheList() async {
        let rig = ShelfRig(rows: rows(1..<3))
        rig.paster.result = .failure(FlotsamError(.libIo001, "gone"))
        await rig.openSticky()
        let before = rig.source.queries.count
        rig.model.handle(KeyStroke(.returnKey))
        await rig.model.settled()
        #expect(rig.probe.reports.map(\.code) == [.libIo001])
        #expect(rig.source.queries.count > before)
    }

    // MARK: FR-006-09 mouse

    @Test func oc6059_doubleClickPastesThatCardIntoTheTarget() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.doubleClick(shelfID(2))
        await rig.model.settled()
        #expect(rig.paster.calls == [.init(itemId: shelfID(2), mode: .paste, target: textEdit)])
        #expect(rig.host.hideCount == 1)
    }

    @Test func oc6060_doubleClickPastesOnlyTheCardUnderThePointerNotTheSelection() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(1), modifiers: .command)
        rig.model.click(shelfID(3), modifiers: .command)
        rig.model.doubleClick(shelfID(2))
        await rig.model.settled()
        #expect(rig.paster.calls.map(\.itemId) == [shelfID(2)])
        #expect(rig.model.selection == [shelfID(2)])
    }

    @Test func oc6061_aSingleClickOnlySelects() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(3))
        await rig.model.settled()
        #expect(rig.model.selection == [shelfID(3)])
        #expect(rig.paster.calls.isEmpty)
        #expect(rig.host.hideCount == 0)
    }

    @Test func oc6062_shiftClickBackwardsSelectsTheSameRange() async {
        let rig = ShelfRig(rows: rows(1..<5))
        await rig.openSticky()
        rig.model.click(shelfID(4))
        rig.model.click(shelfID(2), modifiers: .shift)
        #expect(rig.model.selection == [shelfID(2), shelfID(3), shelfID(4)])
    }

    @Test func oc6062_clickThenShiftClickSelectsTheRangeAndCommandClickToggles() async {
        let rig = ShelfRig(rows: rows(1..<5))
        await rig.openSticky()
        rig.model.click(shelfID(1))
        rig.model.click(shelfID(3), modifiers: .shift)
        #expect(rig.model.selection == [shelfID(1), shelfID(2), shelfID(3)])
        rig.model.click(shelfID(2), modifiers: .command)
        #expect(rig.model.selection == [shelfID(1), shelfID(3)])
        rig.model.click(shelfID(2), modifiers: .command)
        #expect(rig.model.selection == [shelfID(1), shelfID(2), shelfID(3)])
        rig.model.click(shelfID(4))
        #expect(rig.model.selection == [shelfID(4)])
    }

    @Test func oc6063_theContextMenuHasExactlyTheSevenEntriesInOrder() async {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2, pinned: true)])
        await rig.openSticky()
        let unpinned: [ShelfMenuEntry] = [
            .item(.paste, titleKey: "ui.library.menuPaste"), .item(.pastePlain, titleKey: "ui.library.menuPastePlain"),
            .item(.copy, titleKey: "ui.library.menuCopy"), .separator,
            .item(.togglePin, titleKey: "ui.shelf.menuPin"), .separator,
            .item(.delete, titleKey: "ui.shelf.menuDelete"),
        ]
        var pinned = unpinned
        pinned[4] = .item(.togglePin, titleKey: "ui.shelf.menuUnpin")
        #expect(rig.model.contextMenu(for: shelfID(1)) == unpinned)
        #expect(rig.model.contextMenu(for: shelfID(2)) == pinned)
    }

    @Test func oc6064_pinFromTheMenuPinsAnUnpinnedCardAndAMixedSelectionPinsAll() async {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2, pinned: true), makeShelfRow(3)])
        await rig.openSticky()
        rig.model.perform(.togglePin, on: shelfID(3))
        await rig.model.settled()
        #expect(rig.source.pinCalls.last?.ids == [shelfID(3)])
        #expect(rig.source.pinCalls.last?.pinned == true)
        #expect(rig.model.sections()[0].cards.map(\.id).contains(shelfID(3)))

        // Selecting a pinned and an unpinned card: any unpinned means pin all (FR-004-01), and the menu says Pin.
        rig.model.click(shelfID(1))
        rig.model.click(shelfID(2), modifiers: .command)
        #expect(rig.model.contextMenu(for: shelfID(1))[4] == .item(.togglePin, titleKey: ShelfText.menuPin))
        rig.model.perform(.togglePin, on: shelfID(1))
        await rig.model.settled()
        #expect(rig.source.pinCalls.last?.pinned == true)
        #expect(Set(rig.source.pinCalls.last?.ids ?? []) == [shelfID(1), shelfID(2)])

        // Now all selected are pinned, so the same action unpins them all.
        #expect(rig.model.contextMenu(for: shelfID(1))[4] == .item(.togglePin, titleKey: ShelfText.menuUnpin))
        rig.model.perform(.togglePin, on: shelfID(1))
        await rig.model.settled()
        #expect(rig.source.pinCalls.last?.pinned == false)
    }

    @Test func oc6065_deletingAPinnedCardAsksFirstAndCancelLeavesItInPlace() async {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2, pinned: true), makeShelfRow(3)]) { $0.confirmAnswer = false }
        await rig.openSticky()
        rig.model.perform(.delete, on: shelfID(2))
        await rig.model.settled()
        #expect(rig.probe.confirmQuestions == [DeleteConfirmation.message(count: 1)])
        #expect(rig.source.deleteCalls.isEmpty)
        #expect(rig.model.orderedRows.count == 3)

        rig.probe.confirmAnswer = true
        rig.model.perform(.delete, on: shelfID(2))
        await rig.model.settled()
        #expect(rig.probe.confirmQuestions.count == 2)
        #expect(rig.source.deleteCalls == [[shelfID(2)]])
        #expect(rig.model.orderedRows.map(\.id) == [shelfID(1), shelfID(3)])
    }

    @Test func oc6065_theConfirmationIsFRD004sTextForOneItemAndForSeveral() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(1))
        rig.model.click(shelfID(2), modifiers: .command)
        rig.model.perform(.delete, on: shelfID(1))
        await rig.model.settled()
        #expect(rig.probe.confirmQuestions == [DeleteConfirmation.message(count: 2)])
        #expect(DeleteConfirmation.message(count: 2) != DeleteConfirmation.message(count: 1))
        #expect(!DeleteConfirmation.message(count: 2).isEmpty)
    }

    @Test func oc6066_deletingOneUnpinnedCardNeedsNoConfirmationAndSelectionMovesToTheNextCard() async {
        let rig = ShelfRig(rows: rows(1..<5))
        await rig.openSticky()
        rig.model.click(shelfID(2))
        rig.model.perform(.delete, on: shelfID(2))
        await rig.model.settled()
        #expect(rig.probe.confirmQuestions.isEmpty)
        #expect(rig.source.deleteCalls == [[shelfID(2)]])
        #expect(rig.model.orderedRows.map(\.id) == [shelfID(1), shelfID(3), shelfID(4)])
        #expect(rig.model.selection == [shelfID(3)])
    }

    @Test func oc6066_deletingTheLastCardSelectsThePreviousOne() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(3))
        rig.model.perform(.delete, on: shelfID(3))
        await rig.model.settled()
        #expect(rig.model.selection == [shelfID(2)])
    }

    // MARK: Helpers

    /// Waits up to a second for `condition`, which a bus event reaches through a main-actor hop and a load.
    private func settle(_ rig: ShelfRig, until condition: () -> Bool) async {
        for _ in 0..<100 {
            await rig.model.settled()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
