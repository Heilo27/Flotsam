import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// FRD-003 8T, contract OC-3029 to OC-3041 (the keyboard map, FR-003-08 / AC-003-06 / AC-003-18). The expected side is a
// literal from .claude/oracle/frd-003-contract.json. What FRD-004 and FRD-005 do with the organise keys (pin, tags,
// note, edit, ungroup, shortcut) is not built in this repo; the Library's obligation is the key -> command mapping and
// the exact set of ids it hands on, and that is what these tests pin. Each such test says which half it cannot reach.

@MainActor
@Suite struct Frd003ContractKeysTests {
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    private func opened(_ rows: [ItemRow]) async -> Harness {
        let harness = Harness(rows: rows)
        await harness.model.open(target: target)
        return harness
    }

    private func key(_ input: LibraryKeyInput, _ modifiers: ChordModifiers = []) -> LibraryKeyStroke {
        LibraryKeyStroke(input, modifiers)
    }

    /// Polls until `condition` holds, for work the model starts in an unstructured Task (reveal).
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: Reveal (OC-3029)

    // OC-3029. Mutation: reveal the wrong member, reveal on a multi-selection, or drop the call.
    @Test("OC-3029 Command-R asks Finder to reveal the selected file's path")
    func oc3029_reveal() async {
        // given: three rows, the newest is a file item for /tmp/oc/r.txt, and it is selected
        let rows = Harness.rows(3)
        let h = await opened(rows)
        h.source.content = ItemContent(
            kind: .file, plainText: nil, representations: [],
            members: [ItemMember(path: "/tmp/oc/r.txt", bookmark: nil, isDirectory: false)])
        h.model.select(id: rows[0].id)
        // when: Command-R
        #expect(h.model.handle(key(.character("r"), .command)))
        await eventually { !h.reported.revealed.isEmpty }
        // then: exactly one reveal, of exactly that path
        #expect(h.reported.revealed == [["/tmp/oc/r.txt"]])
    }

    // OC-3029 negative. Mutation: reveal with nothing or several selected.
    @Test("OC-3029 Command-R does nothing with two rows selected or with no file members")
    func oc3029_revealNegative() async {
        // given: a file-like content, two rows selected
        let rows = Harness.rows(3)
        let h = await opened(rows)
        h.source.content = ItemContent(
            kind: .file, plainText: nil, representations: [],
            members: [ItemMember(path: "/tmp/oc/r.txt", bookmark: nil, isDirectory: false)])
        h.model.select(id: rows[0].id)
        h.model.handle(key(.down, .shift))
        #expect(h.model.selection.count == 2)
        // when
        h.model.handle(key(.character("r"), .command))
        try? await Task.sleep(for: .milliseconds(150))
        // then: nothing revealed
        #expect(h.reported.revealed.isEmpty)
        // and: one row selected, but a text item (no members) is not revealed either
        h.source.content = ItemContent(kind: .text, plainText: "t", representations: [], members: [])
        h.model.select(id: rows[1].id)
        h.model.handle(key(.character("r"), .command))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(h.reported.revealed.isEmpty)
    }

    // MARK: Organise keys hand the exact ids on (OC-3030, 3031, 3034, 3039, 3041)

    // OC-3030. The Pinned badge and count are FRD-004's; the Library's half is the key and the id. Mutation: map
    // Command-P to another command, or hand on the wrong ids.
    @Test("OC-3030 Command-P twice asks to pin the one selected item both times")
    func oc3030_pinKey() async {
        // given: one unpinned item selected
        let rows = Harness.rows(4)
        let h = await opened(rows)
        h.model.select(id: rows[2].id)
        // when: Command-P, then Command-P again
        #expect(h.model.handle(key(.character("p"), .command)))
        #expect(h.model.handle(key(.character("p"), .command)))
        // then: two pin commands, each for exactly the selected id
        #expect(h.reported.external.map(\.0) == [.pin, .pin])
        #expect(h.reported.external.map(\.1) == [[rows[2].id], [rows[2].id]])
    }

    // OC-3030 negative. Mutation: let a bare "p" (typing in the search field) trigger pin.
    @Test("OC-3030 a bare p and Command-Shift-P are not the pin key; they reach the search field")
    func oc3030_pinNegative() async {
        // given: an item selected
        let rows = Harness.rows(2)
        let h = await opened(rows)
        h.model.select(id: rows[0].id)
        // when: p alone and with Command+Shift
        let bare = h.model.handle(key(.character("p")))
        let shifted = h.model.handle(key(.character("p"), [.command, .shift]))
        // then: neither is handled, and nothing was handed on
        #expect(!bare)
        #expect(!shifted)
        #expect(h.reported.external.isEmpty)
    }

    // OC-3031. Mutation: swap two of the four keys, or drop one.
    @Test("OC-3031 Command-T, N, E and K map to tags, note, edit and shortcut-and-trigger for the selected item")
    func oc3031_editorKeys() async {
        // given: a text item selected
        let rows = Harness.rows(3)
        let h = await opened(rows)
        h.model.select(id: rows[1].id)
        // when: the four keys, in turn
        for letter in ["t", "n", "e", "k"] {
            #expect(h.model.handle(key(.character(Character(letter)), .command)))
        }
        // then: in order tags, note, edit, shortcutAndTrigger, each for that item only
        #expect(h.reported.external.map(\.0) == [.tags, .note, .edit, .shortcutAndTrigger])
        #expect(h.reported.external.allSatisfy { $0.1 == [rows[1].id] })
    }

    // OC-3034. The ungroup outcome (3 files, count n + 2) is FRD-004's. Mutation: wrong chord (without Shift).
    @Test("OC-3034 Command-Shift-U maps to ungroup for the selected bundle; Command-U alone does not")
    func oc3034_ungroupKey() async {
        // given: a bundle row selected
        let bundle = makeRow(7, kind: .bundle, primary: "3 items · b1.txt, b2.txt")
        let h = await opened([bundle, makeRow(8)])
        h.model.select(id: bundle.id)
        // when
        #expect(h.model.handle(key(.character("u"), [.command, .shift])))
        let plain = h.model.handle(key(.character("u"), .command))
        // then: one ungroup for the bundle; Command-U is not the Library's
        #expect(h.reported.external.map(\.0) == [.ungroup])
        #expect(h.reported.external.map(\.1) == [[bundle.id]])
        #expect(!plain)
    }

    // OC-3039. The badges and the Pinned count (+2) are FRD-004's. Mutation: hand on only the cursor row.
    @Test("OC-3039 Command-P with two rows selected hands both ids on")
    func oc3039_pinTwo() async {
        // given: two rows selected with Shift-Down
        let rows = Harness.rows(5)
        let h = await opened(rows)
        h.model.handle(key(.down, .shift))
        #expect(h.model.selection == [rows[0].id, rows[1].id])
        // when
        #expect(h.model.handle(key(.character("p"), .command)))
        // then: one pin command carrying exactly the two selected ids
        #expect(h.reported.external.map(\.0) == [.pin])
        #expect(Set(h.reported.external.first?.1 ?? []) == [rows[0].id, rows[1].id])
        #expect(h.reported.external.first?.1.count == 2)
    }

    // OC-3041. The tag chip, the Tags count and the note search are FRD-004's. Mutation: tag only one of the two.
    @Test("OC-3041 Command-T then Command-N with two rows selected each carry both ids")
    func oc3041_tagAndNoteTwo() async {
        // given: two rows selected
        let rows = Harness.rows(5)
        let h = await opened(rows)
        h.model.handle(key(.down, .shift))
        // when
        h.model.handle(key(.character("t"), .command))
        h.model.handle(key(.character("n"), .command))
        // then: tags then note, each for both ids, and not for the third row
        #expect(h.reported.external.map(\.0) == [.tags, .note])
        for call in h.reported.external {
            #expect(Set(call.1) == [rows[0].id, rows[1].id])
            #expect(call.1.count == 2)
        }
    }

    // MARK: Settings, row shortcuts, passthrough (OC-3035..3037)

    // OC-3035. The window itself is the App layer. Mutation: drop the mapping, or fire on a bare comma.
    @Test("OC-3035 Command-comma opens Settings once; a bare comma does not")
    func oc3035_settings() async {
        // given: the Library open
        let h = await opened(Harness.rows(2))
        // when: a bare comma, then Command-comma
        let bare = h.model.handle(key(.character(",")))
        #expect(h.reported.settingsOpened == 0)
        #expect(h.model.handle(key(.character(","), .command)))
        // then: the bare comma is the search field's; Settings opened exactly once
        #expect(!bare)
        #expect(h.reported.settingsOpened == 1)
    }

    // OC-3036. Closing the panel is PasteService's (FR-003-15), reached through the host; the fake paster does not
    // hide it, so the close half is covered by the paste-service tests, not here. Mutation: pasteRow off by one.
    @Test("OC-3036 Command-3 pastes the third visible row into the target app")
    func oc3036_pasteRowThree() async {
        // given: 10 items, empty query
        let rows = Harness.rows(10)
        let h = await opened(rows)
        // when: Command-3
        #expect(h.model.handle(key(.character("3"), .command)))
        await h.model.pasteTask?.value
        // then: one paste of exactly rows[2], plain paste mode, into the recorded target
        #expect(h.paster.calls == [FakePaster.Call(itemId: rows[2].id, mode: .paste, target: target)])
    }

    // OC-3036 boundaries. Mutation: allow a digit beyond the row count, or limit to fewer than nine.
    @Test("OC-3036 Command-digit pastes only when that visible row exists", arguments: [
        (9, 1, 0), (9, 9, 1), (9, 8, 0), (1, 1, 1), (2, 1, 0), (3, 0, 0),
    ])
    func oc3036_boundaries(digit: Int, rowCount: Int, expectedPastes: Int) async {
        // given: `rowCount` rows
        let rows = Harness.rows(rowCount)
        let h = await opened(rows)
        // when: Command-<digit>
        h.model.handle(key(.character(Character(String(digit))), .command))
        await h.model.pasteTask?.value
        // then
        #expect(h.paster.calls.count == expectedPastes)
        if expectedPastes == 1 { #expect(h.paster.calls.first?.itemId == rows[digit - 1].id) }
    }

    // OC-3037. The dead-key composition is AppKit's; the package's obligation is that these strokes are NOT claimed.
    // Mutation: claim option-e, or claim plain letters.
    @Test("OC-3037 option-e, e, a and c are not the Library's, so they reach the search field")
    func oc3037_unhandledReachSearch() async {
        // given: the Library open
        let h = await opened(Harness.rows(3))
        // when: the strokes of option-e, e, a, c
        let strokes = [key(.character("e"), .option), key(.character("e")), key(.character("a")), key(.character("c"))]
        let handled = strokes.map { h.model.handle($0) }
        // then: none handled, nothing handed on, no paste
        #expect(handled == [false, false, false, false])
        #expect(h.reported.external.isEmpty)
        #expect(h.paster.calls.isEmpty)
    }

    // OC-3037 boundary: Space types a space once the field has text, previews while it is empty.
    @Test("OC-3037 Space is a typed character once the search field has text")
    func oc3037_spaceTypes() async {
        // given: the Library open with search text 'ac'
        let h = await opened(Harness.rows(3))
        h.model.setSearchText("ac")
        await h.model.settled()
        // when
        let handled = h.model.handle(key(.space))
        // then: not claimed (it goes to the field); the preview stayed closed
        #expect(!handled)
        #expect(!h.model.isPreviewOpen)
    }

    // MARK: Multi-selection disables the paste keys (OC-3038)

    // OC-3038. The TextEdit changeCount / document half needs Accessibility and a live app (not coverable here).
    // Mutation: paste the cursor row, or paste every selected row, or close the panel.
    @Test("OC-3038 with two rows selected, Return, Option-Return and Shift-Return paste nothing and the footer says so")
    func oc3038_multiDisablesPaste() async {
        // given: Accessibility granted, two rows selected with Shift-Down
        let rows = Harness.rows(4)
        let h = await opened(rows)
        h.model.handle(key(.down, .shift))
        #expect(h.model.selection.count == 2)
        // when: the three paste chords
        for modifiers: ChordModifiers in [[], .option, .shift] { h.model.handle(key(.returnKey, modifiers)) }
        await h.model.pasteTask?.value
        // then: nothing pasted, the panel never hid, the selection is intact, the footer reads the literals
        #expect(h.paster.calls.isEmpty)
        #expect(h.host.hideCount == 0)
        #expect(h.model.selection.count == 2)
        #expect(h.model.footer().countText == "2 selected")
        #expect(h.model.footer().notice == "Select one item to paste")
    }

    // OC-3038 control: with one row selected the same Return does paste (so the test above can fail for the right reason).
    @Test("OC-3038 control: with one row selected, Return pastes it and the footer has no multi notice")
    func oc3038_singleStillPastes() async {
        // given: one row selected
        let rows = Harness.rows(4)
        let h = await opened(rows)
        h.model.select(id: rows[1].id)
        // when
        h.model.handle(key(.returnKey))
        await h.model.pasteTask?.value
        // then
        #expect(h.paster.calls.map(\.itemId) == [rows[1].id])
        #expect(h.model.footer().countText == "4 items")
        #expect(h.model.footer().notice != "Select one item to paste")
    }
}
