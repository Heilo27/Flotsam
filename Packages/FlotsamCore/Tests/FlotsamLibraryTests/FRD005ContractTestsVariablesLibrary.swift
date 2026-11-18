import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// FRD-005 8T contract tests, slice S8, the Library half of OC-5107 (FR-005-16) and OC-5117 (AC-005-16, BR-4): Return,
// ⌥Return, ⇧Return (Copy) and the Space preview on a real Library over a real database, with the real PasteService and
// a recording pasteboard. Expected values are literals. UNTESTABLE-AT-PACKAGE for the Shelf drag into TextEdit: see
// FlotsamShelfTests/FRD005ContractTestsVariablesShelf (the drag plan is asserted there; the missing seam is the AppKit
// drag pasteboard and TextEdit).

@MainActor
@Suite struct FRD005ContractTestsVariablesLibrary {
    // Red if a Library paste mode skips the pasteboard write (the clipboard stays 'prev') or writes another item.
    @Test("OC-5107 after Return, then ⌥Return, then ⇧Return, the clipboard holds P's content each time, not 'prev'")
    func oc5107_clipboardHoldsItemAfterEachMode() async throws {
        // given: 'prev' on the clipboard (the board's last write), item P selected, a bystander Q
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        let p = try await rig.lib.add(.text, key: "p5107", text: "P-content-5107", secondsAgo: 5).itemId
        let q = try await rig.lib.add(.text, key: "q5107", text: "Q-bystander", secondsAgo: 50).itemId
        _ = rig.pasteboard.write([PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("prev".utf8))])
        #expect(rig.pasteboard.lastText == "prev")
        var seen: [String?] = []
        // when: Return, ⌥Return, ⇧Return, each on P with the clipboard put back to 'prev' beforehand
        for (input, modifiers) in [(KeyInput.returnKey, ChordModifiers()), (.returnKey, .option), (.returnKey, .shift)] {
            _ = rig.pasteboard.write([PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("prev".utf8))])
            await rig.reopen()
            rig.model.select(id: p)
            await rig.press(input, modifiers)
            seen.append(rig.pasteboard.lastText)
        }
        // then: P's text after every one; the bystander was never written; three pastes counted on P, none on Q
        #expect(seen == ["P-content-5107", "P-content-5107", "P-content-5107"])
        #expect(try await rig.pasteCount(p) == 3)
        #expect(try await rig.pasteCount(q) == 0)
        #expect(rig.keys.posts == 2)
    }

    // Red if the Library paste path, Copy or the preview expands variables (BR-4).
    @Test("OC-5117 Return, Copy and the preview of item '{date}' (trigger ';d') all give the literal '{date}'")
    func oc5117_libraryIsLiteral() async throws {
        // given: an item '{date}' bound to ';d' (stored), and a bystander
        let rig = try await PasteRig.make()
        defer { rig.lib.cleanUp() }
        let item = try await rig.lib.add(.text, key: "d5117", text: "{date}", secondsAgo: 5).itemId
        let other = try await rig.lib.add(.text, key: "o5117", text: "{time}", secondsAgo: 50).itemId
        let bound = try await rig.lib.database.applyExemptionEdit(.setTrigger(";d"), to: item).get()
        #expect(bound)
        #expect(try await rig.lib.database.itemBindings().get().triggers == [item: ";d"])
        // when: Return
        await rig.reopen()
        rig.model.select(id: item)
        await rig.press(.returnKey)
        // then: ⌘V posted, the literal is what it pastes
        #expect(rig.keys.posts == 1)
        #expect(rig.pasteboard.lastText == "{date}")
        // when: Copy (⇧Return)
        await rig.reopen()
        rig.model.select(id: item)
        await rig.press(.returnKey, .shift)
        // then: no further ⌘V, the clipboard holds the literal
        #expect(rig.keys.posts == 1)
        #expect(rig.pasteboard.lastText == "{date}")
        #expect(rig.pasteboard.written.count == 2)
        // when: the preview is opened
        await rig.reopen()
        rig.model.select(id: item)
        rig.model.handle(LibraryKeyStroke(.space, []))
        await rig.model.awaitPreview()
        // then: it shows the literal and is the item's, not the bystander's
        #expect(rig.model.preview?.itemId == item)
        #expect(rig.model.preview?.text(showingAll: true) == "{date}")
        #expect(try await rig.pasteCount(other) == 0)
    }
}
