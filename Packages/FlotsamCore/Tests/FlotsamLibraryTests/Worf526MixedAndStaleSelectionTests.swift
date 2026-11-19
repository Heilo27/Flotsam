import FlotsamBase
import Foundation
import Testing
@testable import FlotsamLibrary

/// Worf, TASK-526 blind verify (FR-005-09, FR-003-22, AC-005-08a). The ruling: the editor opens for exactly one item
/// that is not secure; several items, or a secure item, open nothing and never hide the Library. Expected values are
/// literals from the ruling, none computed with `ShortcutEditorRule`.
@MainActor
@Suite struct Worf526MixedAndStaleSelectionTests {
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    private func menuHasEditorRow(_ row: ItemRow, singleTarget: Bool) -> Bool {
        LibraryContextMenu.entries(kind: row.kind, pinUnpins: false, singleTarget: singleTarget, isSecure: row.isSecure)
            .contains { if case .item(let key, _, _) = $0 { return key == LibraryText.menuShortcutAndTrigger } else { return false } }
    }

    /// What the context-menu button does in LibraryRows.swift: select the row if it is not in the selection, then perform.
    private func menuAction(on row: ItemRow, in model: LibraryViewModel) {
        if !model.selection.contains(row.id) { model.select(id: row.id) }
        model.perform(.external(.shortcutAndTrigger))
    }

    // Red if the rule looks at only the first or only the last selected row, or at "any non-secure" instead of count.
    @Test func mixedSecureAndOrdinarySelectionOpensNothingAndKeepsTheLibrary() async {
        for secureFirst in [true, false] {
            let rows = secureFirst ? [makeRow(1, secure: true), makeRow(2)] : [makeRow(1), makeRow(2, secure: true)]
            let h = Harness(rows: rows)
            await h.model.open(target: target)
            h.model.select(id: rows[0].id)
            h.model.perform(.extend(.down))
            #expect(h.model.selectedRows.count == 2, "secureFirst \(secureFirst)")
            h.model.handle(LibraryKeyStroke(.character("k"), .command))
            #expect(h.reported.external.isEmpty, "secureFirst \(secureFirst)")
            #expect(h.host.hideCount == 0, "secureFirst \(secureFirst)")
            #expect(h.host.isPanelVisible, "secureFirst \(secureFirst)")
        }
    }

    // The menu on either row of a mixed selection has no editor row (the row's own singleTarget is false).
    @Test func menuOnAMixedSelectionHasNoEditorRowForEitherRow() {
        #expect(!menuHasEditorRow(makeRow(1, secure: true), singleTarget: false))
        #expect(!menuHasEditorRow(makeRow(2), singleTarget: false))
    }

    // 0/1/2/3 boundary over a list of three with a secure middle row: only the lone ordinary rows resolve, each to itself.
    @Test func eachLoneRowInAListWithASecureOneResolvesOnlyWhenOrdinary() async {
        let rows = [makeRow(1), makeRow(2, secure: true), makeRow(3)]
        let h = Harness(rows: rows)
        await h.model.open(target: target)
        var opened: [UUID] = []
        for row in rows {
            h.model.select(id: row.id)
            let before = h.reported.external.count
            h.model.handle(LibraryKeyStroke(.character("k"), .command))
            if h.reported.external.count == before + 1, let id = h.reported.external.last?.1.first { opened.append(id) }
            #expect(h.reported.external.count - before <= 1)
        }
        #expect(opened == [rows[0].id, rows[2].id])
        #expect(h.reported.external.allSatisfy { $0.1.count == 1 })
        // The Library hides once per editor that opens (the two ordinary rows) and never for the secure one (TASK-524).
        #expect(h.host.hideCount == 2)
    }

    // Menu opened on ordinary A (not selected) while secure S is the selection: the action selects A and opens A, never S.
    @Test func menuActionOnAnUnselectedOrdinaryRowOpensThatRowNotTheSecureSelection() async {
        let secure = makeRow(1, secure: true)
        let ordinary = makeRow(2)
        let h = Harness(rows: [secure, ordinary])
        await h.model.open(target: target)
        h.model.select(id: secure.id)
        menuAction(on: ordinary, in: h.model)
        #expect(h.reported.external.count == 1)
        #expect(h.reported.external.first?.1 == [ordinary.id])
    }

    // Menu opened on secure S: the entry is not offered, and if its command is performed anyway nothing reaches the app.
    @Test func menuActionOnASecureRowEvenIfPerformedAnywayOpensNothing() async {
        let secure = makeRow(1, secure: true)
        let ordinary = makeRow(2)
        let h = Harness(rows: [secure, ordinary])
        await h.model.open(target: target)
        h.model.select(id: ordinary.id)
        #expect(!menuHasEditorRow(secure, singleTarget: true))
        menuAction(on: secure, in: h.model)
        #expect(h.reported.external.isEmpty)
        #expect(h.host.hideCount == 0)
    }

    // Menu built for ordinary A as a single target; before the action the selection grows to {A, secure S}. The action
    // re-reads the live selection, so it opens nothing (a stale menu cannot open an editor for two items).
    @Test func selectionGrowingAfterTheMenuOpenedOpensNothing() async {
        let a = makeRow(1)
        let s = makeRow(2, secure: true)
        let h = Harness(rows: [a, s])
        await h.model.open(target: target)
        h.model.select(id: a.id)
        #expect(menuHasEditorRow(a, singleTarget: true))
        h.model.perform(.extend(.down))
        menuAction(on: a, in: h.model)
        #expect(h.model.selectedRows.count == 2)
        #expect(h.reported.external.isEmpty)
        #expect(h.host.hideCount == 0)
    }

    // The predicate as a literal table (the only place the four inputs are written out).
    @Test func ruleTruthTable() {
        #expect(ShortcutEditorRule.allows(isSingleItem: true, isSecure: false) == true)
        #expect(ShortcutEditorRule.allows(isSingleItem: true, isSecure: true) == false)
        #expect(ShortcutEditorRule.allows(isSingleItem: false, isSecure: false) == false)
        #expect(ShortcutEditorRule.allows(isSingleItem: false, isSecure: true) == false)
    }

    // Non-editor commands never resolve to a target, even for an ordinary single row, and a secure row is no exception to nil.
    @Test func otherCommandsNeverResolveForOrdinaryOrSecureRows() {
        let others: [LibraryExternalCommand] = [.pin, .tags, .note, .edit, .delete, .cycleSort, .ungroup]
        for command in others {
            #expect(command.shortcutEditorTarget(selection: [makeRow(1)]) == nil)
            #expect(command.shortcutEditorTarget(selection: [makeRow(1, secure: true)]) == nil)
        }
    }
}
