import FlotsamBase
import Foundation
import Testing
@testable import FlotsamLibrary

/// TASK-526 (FR-005-09, FRD-001 FR-001-25): a secure item can carry no hotkey or trigger, so ⌘K opens nothing on it and
/// the context menu has no "Shortcut and Trigger..." row for it. Both read `ShortcutEditorRule` through
/// `shortcutEditorTarget(selection:)`; these tests hold the two surfaces to the one answer.
@MainActor
@Suite struct Task526SecureShortcutEditorTests {
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)
    private let menuTitle = LibraryText.menuShortcutAndTrigger

    private func menuOffersEditor(_ row: ItemRow, singleTarget: Bool = true) -> Bool {
        LibraryContextMenu.entries(kind: row.kind, pinUnpins: false, singleTarget: singleTarget, isSecure: row.isSecure)
            .contains { entry in
                if case .item(let key, _, _) = entry { return key == menuTitle }
                return false
            }
    }

    private func commandKReachesApp(_ row: ItemRow) async -> UUID? {
        let h = Harness(rows: [row])
        await h.model.open(target: target)
        h.model.select(id: row.id)
        h.model.handle(LibraryKeyStroke(.character("k"), .command))
        return h.reported.external.first(where: { $0.0 == .shortcutAndTrigger })?.1.first
    }

    // Red if the secure check leaves the key path (⌘K reaches the app for a secure row).
    @Test func commandKOnASecureItemDoesNothing() async {
        let secure = makeRow(1, secure: true)
        #expect(await commandKReachesApp(secure) == nil)
    }

    // Control: the same call for an ordinary item still opens it, so the line above is a real refusal.
    @Test func commandKOnAnOrdinaryItemStillOpensTheEditor() async {
        let ordinary = makeRow(2)
        #expect(await commandKReachesApp(ordinary) == ordinary.id)
    }

    // The context-menu row goes through `perform`, the same entry ⌘K reaches.
    @Test func performingTheMenuCommandOnASecureItemDoesNothing() async {
        let secure = makeRow(3, secure: true)
        let h = Harness(rows: [secure])
        await h.model.open(target: target)
        h.model.select(id: secure.id)
        h.model.perform(.external(.shortcutAndTrigger))
        #expect(h.reported.external.isEmpty)
    }

    // The two surfaces agree for every kind, secure or not: the row is in the menu exactly when ⌘K would open the editor.
    // Red if either surface stops reading the shared rule (a copy of `!isSecure` drifts, or one surface drops it).
    @Test func menuRowAndKeyAgreeForEveryKindAndSecurity() async {
        for kind in ItemKind.allCases {
            for secure in [false, true] {
                let row = makeRow(4, kind: kind, secure: secure)
                let opens = await commandKReachesApp(row) != nil
                #expect(menuOffersEditor(row) == opens, "kind \(kind) secure \(secure)")
                #expect(opens == !secure, "kind \(kind) secure \(secure)")
            }
        }
    }

    // FR-003-22 ruling: with several items selected the menu has no "Shortcut and Trigger..." row, because ⌘K opens
    // nothing for them. Red if the row returns for a multi-item target, for any kind, secure or not.
    @Test func menuHasNoEditorRowForSeveralItems() {
        for kind in ItemKind.allCases {
            for secure in [false, true] {
                #expect(!menuOffersEditor(makeRow(5, kind: kind, secure: secure), singleTarget: false), "kind \(kind) secure \(secure)")
            }
        }
    }

    // The same selection through ⌘K: two ordinary rows open nothing, which is why the row above is absent.
    @Test func commandKWithSeveralOrdinaryItemsDoesNothing() async {
        let rows = [makeRow(6), makeRow(7)]
        let h = Harness(rows: rows)
        await h.model.open(target: target)
        h.model.select(id: rows[0].id)
        h.model.perform(.extend(.down))
        #expect(h.model.selectedRows.count == 2)
        h.model.handle(LibraryKeyStroke(.character("k"), .command))
        #expect(h.reported.external.isEmpty)
    }
}
