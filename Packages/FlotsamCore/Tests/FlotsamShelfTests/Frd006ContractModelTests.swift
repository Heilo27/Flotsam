import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf

/// FRD-006 oracle contract tests for `ShelfModel`: contents (FR-006-06), keyboard (FR-006-08), mouse (FR-006-09).
/// The model runs over fakes at the ShelfDataSource / ShelfPasting / ShelfPasteHost ports (`ShelfRig`). Expected values
/// are the oracle's literals (card numbers, counts, ids, HUD text); none is computed with a production expression.
@MainActor
@Suite struct Frd006ContractModelTests {
    private func rows(_ numbers: Range<Int>, pinned: Bool = false) -> [ItemRow] {
        numbers.map { makeShelfRow($0, pinned: pinned) }
    }

    private func ids(_ range: ClosedRange<Int>) -> [UUID] { range.map(shelfID) }

    // MARK: FR-006-06 contents

    // OC-6038. given 25 pinned and 30 unpinned items (pinned newest), then Pinned shows the 20 newest pinned, Recent the
    // 20 newest unpinned, each newest first. Red if a section is uncapped, reordered, or Recent is fed pinned rows.
    @Test("OC-6038 25 pinned and 30 unpinned: Pinned shows cards 1...20 and Recent shows cards 26...45, in order")
    func oc6038_twentyNewestEach_pinnedNewest() async {
        let rig = ShelfRig(rows: rows(1..<26, pinned: true) + rows(26..<56))
        await rig.openSticky()
        let sections = rig.model.sections()
        #expect(sections.map(\.kind) == [.pinned, .recent])
        #expect(sections[0].cards.map(\.id) == ids(1...20))
        #expect(sections[1].cards.map(\.id) == ids(26...45))
    }

    // OC-6038 interleaved copy times: pinned items are the odd numbers 1..49, unpinned the even numbers 2..60.
    @Test("OC-6038 with pinned and unpinned interleaved by copy time, each section keeps its own 20 newest")
    func oc6038_twentyNewestEach_interleaved() async {
        var all: [ItemRow] = []
        for n in 1...55 { all.append(makeShelfRow(n, pinned: n % 2 == 1 && n <= 49)) }
        let rig = ShelfRig(rows: all)
        await rig.openSticky()
        let sections = rig.model.sections()
        let pinned = (1...49).filter { $0 % 2 == 1 }.prefix(20).map(shelfID)
        let recent = (1...55).filter { !($0 % 2 == 1 && $0 <= 49) }.prefix(20).map(shelfID)
        #expect(sections[0].cards.map(\.id) == Array(pinned))
        #expect(sections[1].cards.map(\.id) == Array(recent))
        #expect(sections[0].cards.count == 20)
        #expect(sections[1].cards.count == 20)
    }

    // OC-6039. given Recent full (20 cards) and the Shelf visible, when a new item is stored (the bus announces it),
    // then it is the first Recent card, Recent still has 20 cards, and the oldest old card dropped off.
    @Test("OC-6039 a newly stored item becomes the first Recent card and Recent stays at 20")
    func oc6039_newItemLeadsAFullRecent() async {
        let rig = ShelfRig(rows: rows(2..<22))
        await rig.openSticky()
        #expect(rig.model.sections()[0].cards.count == 20)

        rig.source.rows = [makeShelfRow(1, primary: "shelf-new-1")] + rows(2..<22)
        rig.bus.publish(.itemsChanged)
        for _ in 0..<100 {
            await rig.model.settled()
            if rig.model.sections().first?.cards.first?.id == shelfID(1) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let recent = rig.model.sections()[0]
        #expect(recent.kind == .recent)
        #expect(recent.cards.first?.id == shelfID(1))
        #expect(recent.cards.first?.text == "shelf-new-1")
        #expect(recent.cards.count == 20)
        #expect(!recent.cards.map(\.id).contains(shelfID(21)))
    }

    // OC-6041. given 3 pinned and no unpinned items, then only Pinned (3 cards) shows, no Recent section.
    @Test("OC-6041 three pinned and nothing else shows Pinned with 3 cards and no Recent section")
    func oc6041_onlyPinned() async {
        let rig = ShelfRig(rows: rows(1..<4, pinned: true))
        await rig.openSticky()
        let sections = rig.model.sections()
        #expect(sections.map(\.kind) == [.pinned])
        #expect(sections[0].cards.map(\.id) == ids(1...3))
    }

    // OC-6041. given 0 pinned and 3 unpinned, then only Recent (3 cards) shows, no Pinned section.
    @Test("OC-6041 three unpinned and nothing else shows Recent with 3 cards and no Pinned section")
    func oc6041_onlyRecent() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        let sections = rig.model.sections()
        #expect(sections.map(\.kind) == [.recent])
        #expect(sections[0].cards.map(\.id) == ids(1...3))
    }

    // OC-6042. given the Library is filtered or sorted, the Shelf still asks storage for exactly the pinned page and the
    // unfiltered Recent page in copy-time order: it takes no filter or sort from anywhere. Tagged items show too.
    @Test("OC-6042 the Shelf queries pinned-by-recency and all-by-recency, with no text filter, and shows tagged and untagged")
    func oc6042_queriesAreUnfilteredCopyOrder() async {
        let tagged = makeShelfRow(1, tags: ["work"])
        let rig = ShelfRig(rows: [tagged, makeShelfRow(2), makeShelfRow(3, tags: ["home"])])
        await rig.openSticky()
        #expect(rig.source.queries.count == 2)
        #expect(rig.source.queries.allSatisfy { $0.text == "" && $0.page == 0 && $0.sort == .recent })
        #expect(Set(rig.source.queries.map(\.filter)) == [.pinned, .all])
        #expect(rig.model.sections()[0].cards.map(\.id) == ids(1...3))
    }

    // OC-6043. given a visible sticky Shelf, when a Recent card is pinned via its menu, then it moves to Pinned and is
    // gone from Recent (count delta -1 in Recent, +1 in Pinned, identity checked).
    @Test("OC-6043 pinning a Recent card moves it to Pinned and removes it from Recent")
    func oc6043_pinMovesTheCard() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        #expect(rig.model.sections().map(\.kind) == [.recent])
        rig.model.perform(.togglePin, on: shelfID(2))
        await rig.model.settled()
        let sections = rig.model.sections()
        #expect(sections.map(\.kind) == [.pinned, .recent])
        #expect(sections[0].cards.map(\.id) == [shelfID(2)])
        #expect(sections[1].cards.map(\.id) == [shelfID(1), shelfID(3)])
    }

    // OC-6044. given a copy made an instant ago that capture has not stored yet, when the Shelf opens, then capture is
    // flushed BEFORE the list is read, so the new item is the first Recent card in the first frame.
    @Test("OC-6044 opening flushes capture before reading, so 'just-now-1' is the first Recent card")
    func oc6044_captureFlushBeforeRead() async {
        let rig = ShelfRig(rows: rows(2..<4))
        rig.probe.onCapture = { [source = rig.source] in
            source.rows = [makeShelfRow(1, primary: "just-now-1")] + source.rows
        }
        await rig.openSticky()
        #expect(rig.log.entries.first == "captureNow")
        #expect(rig.probe.captureCount == 1)
        let first = rig.model.sections()[0].cards.first
        #expect(first?.id == shelfID(1))
        #expect(first?.text == "just-now-1")
        #expect(rig.model.sections()[0].cards.count == 3)
    }

    // OC-6049. given a file item whose file was deleted, then its card carries the Missing flag, and a present file's
    // card does not.
    @Test("OC-6049 a file item whose file is gone shows Missing; a present one does not")
    func oc6049_missingBadge() async {
        let rig = ShelfRig(rows: [makeShelfRow(1, kind: .file, missing: true), makeShelfRow(2, kind: .file)])
        await rig.openSticky()
        let cards = rig.model.sections()[0].cards
        #expect(cards.map(\.id) == [shelfID(1), shelfID(2)])
        #expect(cards.map(\.isMissing) == [true, false])
    }

    // MARK: FR-006-08 keyboard

    // OC-6050. given a sticky Shelf, when Down, Down, Return, then the THIRD card is pasted into the recorded target,
    // the Shelf hides, and nothing else is pasted.
    @Test("OC-6050 Down, Down, Return pastes the third card into TextEdit and hides the Shelf")
    func oc6050_downDownReturn() async {
        let rig = ShelfRig(rows: [
            makeShelfRow(1), makeShelfRow(2), makeShelfRow(3, primary: "third-card-text"), makeShelfRow(4),
        ])
        await rig.openSticky()
        _ = rig.model.handle(KeyStroke(.down))
        _ = rig.model.handle(KeyStroke(.down))
        _ = rig.model.handle(KeyStroke(.returnKey))
        await rig.model.settled()
        #expect(rig.paster.calls.count == 1)
        #expect(rig.paster.calls.first?.itemId == shelfID(3))
        #expect(rig.paster.calls.first?.mode == .paste)
        #expect(rig.paster.calls.first?.target == FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242))
        #expect(rig.host.hideCount == 1)
    }

    // OC-6051. ⇧Return copies only the selected card; nothing is pasted into the target.
    @Test("OC-6051 ⇧Return copies the selected card and does not paste")
    func oc6051_shiftReturnCopies() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(2))
        _ = rig.model.handle(KeyStroke(.returnKey, .shift))
        await rig.model.settled()
        #expect(rig.paster.calls.map(\.itemId) == [shelfID(2)])
        #expect(rig.paster.calls.map(\.mode) == [.copyOnly])
    }

    // OC-6052. Esc hides the Shelf; no paste and no copy.
    @Test("OC-6052 Esc hides the Shelf and neither pastes nor copies")
    func oc6052_escHides() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        let handled = rig.model.handle(KeyStroke(.escape))
        await rig.model.settled()
        #expect(handled)
        #expect(rig.host.hideCount == 1)
        #expect(rig.paster.calls.isEmpty)
    }

    // OC-6053. ⌥Return pastes the selected card as plain text.
    @Test("OC-6053 ⌥Return pastes the selected card as plain text")
    func oc6053_optionReturnPlain() async {
        let rig = ShelfRig(rows: [makeShelfRow(1, kind: .richText), makeShelfRow(2)])
        await rig.openSticky()
        _ = rig.model.handle(KeyStroke(.returnKey, .option))
        await rig.model.settled()
        #expect(rig.paster.calls.map(\.itemId) == [shelfID(1)])
        #expect(rig.paster.calls.map(\.mode) == [.plainText])
    }

    // OC-6054. ⌘C copies the selected card only.
    @Test("OC-6054 ⌘C copies the selected card and does not paste")
    func oc6054_commandC() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(3))
        let handled = rig.model.handle(KeyStroke(.character("c"), .command))
        await rig.model.settled()
        #expect(handled)
        #expect(rig.paster.calls.map(\.itemId) == [shelfID(3)])
        #expect(rig.paster.calls.map(\.mode) == [.copyOnly])
    }

    // OC-6055. Space is not handled: nothing pasted or copied, selection and open state unchanged.
    @Test("OC-6055 Space does nothing: not handled, no paste or copy, selection and Shelf unchanged")
    func oc6055_spaceDoesNothing() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(2))
        let handled = rig.model.handle(KeyStroke(.space))
        await rig.model.settled()
        #expect(!handled)
        #expect(rig.paster.calls.isEmpty)
        #expect(rig.model.selection == [shelfID(2)])
        #expect(rig.host.hideCount == 0)
        #expect(rig.model.isOpen)
    }

    // OC-6057. given Accessibility off, Return leaves the item on the clipboard and reports SET-PRM-001 whose HUD text is
    // the oracle's literal sentence.
    @Test("OC-6057 Accessibility off: Return reports SET-PRM-001 with the exact HUD sentence")
    func oc6057_accessibilityOff() async {
        let rig = ShelfRig(rows: [makeShelfRow(1, primary: "ax-off")])
        rig.paster.result = .success(.copiedAccessibilityDenied)
        await rig.openSticky()
        _ = rig.model.handle(KeyStroke(.returnKey))
        await rig.model.settled()
        #expect(rig.paster.calls.map(\.itemId) == [shelfID(1)])
        #expect(rig.probe.reports.map(\.code) == [.setPrm001])
        #expect(rig.probe.reports.first.map(FlotsamStrings.message(for:))
            == "Accessibility is off, so Flotsam can't paste for you. The item is on your clipboard; press ⌘V.")
    }

    // OC-6058. given Notes was frontmost when the Shelf opened, Return pastes into Notes (the recorded target), not into
    // anything else.
    @Test("OC-6058 a Shelf opened over Notes pastes into Notes")
    func oc6058_targetIsNotes() async {
        let notes = FrontmostApp(bundleId: "com.apple.Notes", processId: 777)
        let rig = ShelfRig(rows: rows(1..<3))
        await rig.model.open(target: notes, sticky: true)
        _ = rig.model.handle(KeyStroke(.returnKey))
        await rig.model.settled()
        #expect(rig.paster.calls.count == 1)
        #expect(rig.paster.calls.first?.target == notes)
        #expect(rig.paster.calls.first?.itemId == shelfID(1))
    }

    // MARK: FR-006-09 mouse

    // OC-6059. double-click pastes that card into TextEdit and hides the Shelf.
    @Test("OC-6059 double-clicking 'dbl-1' pastes it into TextEdit and hides the Shelf")
    func oc6059_doubleClick() async {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2, primary: "dbl-1"), makeShelfRow(3)])
        await rig.openSticky()
        rig.model.doubleClick(shelfID(2))
        await rig.model.settled()
        #expect(rig.paster.calls.count == 1)
        #expect(rig.paster.calls.first?.itemId == shelfID(2))
        #expect(rig.paster.calls.first?.target == FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242))
        #expect(rig.host.hideCount == 1)
    }

    // OC-6060. ⌘-click 1 and 3, then double-click 2: only card 2 is pasted.
    @Test("OC-6060 after ⌘-clicking cards 1 and 3, double-clicking card 2 pastes only card 2")
    func oc6060_doubleClickIgnoresSelection() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(1), modifiers: .command)
        rig.model.click(shelfID(3), modifiers: .command)
        rig.model.doubleClick(shelfID(2))
        await rig.model.settled()
        #expect(rig.paster.calls.map(\.itemId) == [shelfID(2)])
    }

    // OC-6061. a single click selects and inserts nothing.
    @Test("OC-6061 a single click selects the card and pastes nothing")
    func oc6061_singleClick() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.click(shelfID(2))
        await rig.model.settled()
        #expect(rig.model.selection == [shelfID(2)])
        #expect(rig.paster.calls.isEmpty)
        #expect(rig.host.hideCount == 0)
    }

    // OC-6062. click 1 then ⇧-click 3 selects exactly cards 1 to 3 (card 4 stays out).
    @Test("OC-6062 click card 1 then ⇧-click card 3 selects exactly cards 1, 2 and 3")
    func oc6062_shiftRange() async {
        let rig = ShelfRig(rows: rows(1..<5))
        await rig.openSticky()
        rig.model.click(shelfID(1))
        rig.model.click(shelfID(3), modifiers: .shift)
        #expect(rig.model.selection == Set(ids(1...3)))
        #expect(rig.model.selection.count == 3)
    }

    // OC-6063. the context menu is exactly Paste, Paste as Plain Text, Copy, separator, Pin or Unpin, separator, Delete.
    // Literal string keys: a renamed or reordered entry turns this red.
    @Test("OC-6063 the context menu has exactly seven entries; Pin reads Unpin on a pinned card")
    func oc6063_contextMenu() async {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2, pinned: true)])
        await rig.openSticky()
        let unpinnedMenu = rig.model.contextMenu(for: shelfID(1))
        let pinnedMenu = rig.model.contextMenu(for: shelfID(2))
        #expect(unpinnedMenu.count == 7)
        #expect(pinnedMenu.count == 7)
        #expect(unpinnedMenu == [
            .item(.paste, titleKey: "ui.library.menuPaste"), .item(.pastePlain, titleKey: "ui.library.menuPastePlain"),
            .item(.copy, titleKey: "ui.library.menuCopy"), .separator,
            .item(.togglePin, titleKey: "ui.shelf.menuPin"), .separator,
            .item(.delete, titleKey: "ui.shelf.menuDelete"),
        ])
        #expect(pinnedMenu[4] == .item(.togglePin, titleKey: "ui.shelf.menuUnpin"))
    }

    // OC-6064. choosing Pin on 'pin-me' moves it to Pinned.
    @Test("OC-6064 Pin on an unpinned card moves it to the Pinned section")
    func oc6064_pinMoves() async {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2, primary: "pin-me")])
        await rig.openSticky()
        rig.model.perform(.togglePin, on: shelfID(2))
        await rig.model.settled()
        #expect(rig.source.pinCalls.count == 1)
        #expect(rig.source.pinCalls.first?.ids == [shelfID(2)])
        #expect(rig.source.pinCalls.first?.pinned == true)
        #expect(rig.model.sections().first?.kind == .pinned)
        #expect(rig.model.sections().first?.cards.map(\.id) == [shelfID(2)])
    }

    // OC-6065. a pinned card: Delete asks first; cancel keeps it (count N); confirm removes it (count N-1) and nothing else.
    @Test("OC-6065 deleting a pinned card asks first; cancel keeps all 3, confirm leaves the other 2")
    func oc6065_deletePinnedConfirms() async {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2, primary: "keep-pinned", pinned: true), makeShelfRow(3)]) {
            $0.confirmAnswer = false
        }
        await rig.openSticky()
        rig.model.perform(.delete, on: shelfID(2))
        await rig.model.settled()
        #expect(rig.probe.confirmQuestions.count == 1)
        #expect(rig.source.deleteCalls.isEmpty)
        #expect(rig.source.rows.count == 3)
        #expect(rig.model.orderedRows.count == 3)

        rig.probe.confirmAnswer = true
        rig.model.perform(.delete, on: shelfID(2))
        await rig.model.settled()
        #expect(rig.probe.confirmQuestions.count == 2)
        #expect(rig.source.deleteCalls == [[shelfID(2)]])
        #expect(rig.source.rows.map(\.id) == [shelfID(1), shelfID(3)])
        #expect(rig.model.orderedRows.map(\.id) == [shelfID(1), shelfID(3)])
    }

    // OC-6066. an unpinned card deletes without a confirmation: count N-1, target gone, survivors intact.
    @Test("OC-6066 deleting an unpinned card asks nothing and removes only that card")
    func oc6066_deleteUnpinned() async {
        let rig = ShelfRig(rows: [makeShelfRow(1), makeShelfRow(2, primary: "del-unpinned"), makeShelfRow(3)])
        await rig.openSticky()
        rig.model.perform(.delete, on: shelfID(2))
        await rig.model.settled()
        #expect(rig.probe.confirmQuestions.isEmpty)
        #expect(rig.source.deleteCalls == [[shelfID(2)]])
        #expect(rig.source.rows.map(\.id) == [shelfID(1), shelfID(3)])
        #expect(rig.model.orderedRows.map(\.id) == [shelfID(1), shelfID(3)])
    }

    // OC-6107. (testable half: pasting changes no item count; the copy count is storage's.) A paste with Return leaves the
    // stored item count and every row untouched: no delete, no pin change.
    @Test("OC-6107 pasting a card removes and adds no item")
    func oc6107_pasteChangesNoItems() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        _ = rig.model.handle(KeyStroke(.returnKey))
        await rig.model.settled()
        #expect(rig.paster.calls.count == 1)
        #expect(rig.source.rows.map(\.id) == ids(1...3))
        #expect(rig.source.deleteCalls.isEmpty)
        #expect(rig.source.pinCalls.isEmpty)
    }
}
