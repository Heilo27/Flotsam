import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamShelf

// TASK-434 (Worf, blind): Shelf paste. FlotsamShelf cannot import FlotsamPaste (ADR-0001), so the gate result reaches
// the model as `ShelfPasteOutcome` from the app adapter; this file covers what the model does with it. The adapter's own
// mapping (App/Flotsam/Shelf/ShelfPasteAdapter.swift) is in the App target and is not reachable from `swift test`.
// Contract: OC-6057 (frd-006), FR-006-08, FR-003-17.

@MainActor
@Suite("TASK-434 Shelf paste outcome handling")
struct Worf434PasteGateShelfTests {
    /// FR-006-08. given the paste lands copy-only, then exactly one SET-PRM-001 is reported, carrying the chosen item id
    /// (not another card's), with the catalogue HUD sentence. Red if the model builds the error some other way, drops
    /// the id, or reports twice.
    @Test("OC-6057 copy-only outcome reports one SET-PRM-001 for the chosen item with the catalogue text")
    func copyOnlyReportsOnce() async {
        let rig = ShelfRig(rows: (1..<4).map { makeShelfRow($0) })
        rig.paster.result = .success(.copiedAccessibilityDenied)
        await rig.openSticky()

        await rig.model.paste(itemId: shelfID(2), mode: .paste)

        #expect(rig.paster.calls == [.init(itemId: shelfID(2), mode: .paste, target: textEdit)])
        #expect(rig.probe.reports.count == 1)
        #expect(rig.probe.reports.first?.code == .setPrm001)
        #expect(rig.probe.reports.first?.context[.itemId] == .id(shelfID(2)))
        #expect(rig.probe.reports.first.map { FlotsamStrings.message(for: $0) }
            == "Accessibility is off, so Flotsam can't paste for you. The item is on your clipboard; press ⌘V.")
    }

    /// Inverse. given trusted outcomes (.pasted, .copied), then nothing is reported. Red if the model reports on every
    /// paste.
    @Test("negative: pasted and copied outcomes report nothing")
    func pastedReportsNothing() async {
        let rig = ShelfRig(rows: (1..<3).map { makeShelfRow($0) })
        await rig.openSticky()
        rig.paster.result = .success(.pasted)
        await rig.model.paste(itemId: shelfID(1), mode: .paste)
        rig.paster.result = .success(.copied)
        await rig.model.paste(itemId: shelfID(1), mode: .copyOnly)

        #expect(rig.paster.calls.count == 2)
        #expect(rig.probe.reports.isEmpty)
    }

    /// FR-006-08: the copy-only outcome must not drop the Shelf. Red if a SET-PRM-001 path hides the panel itself (the
    /// fake hides only on a success, as the real service does).
    @Test("copy-only outcome through the keyboard still hands the user the item without a second report")
    func keyboardPathReportsOnce() async {
        let rig = ShelfRig(rows: (1..<3).map { makeShelfRow($0) })
        rig.paster.result = .success(.copiedAccessibilityDenied)
        await rig.openSticky()

        rig.model.handle(KeyStroke(.returnKey))
        await rig.model.settled()

        #expect(rig.probe.reports.map(\.code) == [.setPrm001])
        #expect(rig.probe.reports.first?.context[.itemId] == .id(shelfID(1)))
    }
}
