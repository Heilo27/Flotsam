import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

/// Worf, TASK-317/318 (FR-005-09): what the Library hands the app when the user presses ⌘K. The app's `external`
/// closure (AppContainer.swift) opens the editor only for `.shortcutAndTrigger` with exactly one id; this pins the
/// two inputs that guard depends on: which command ⌘K becomes and which ids come with it.
@MainActor
@Suite struct WorfShortcutEditorRoutingTests {
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    private func opened(_ count: Int) async -> Harness {
        let h = Harness(rows: Harness.rows(count))
        await h.model.open(target: target)
        return h
    }

    // Breaks if ⌘K stops mapping to the shortcut-and-trigger command, or the selection is not passed along.
    @Test func commandKHandsOverTheSingleSelectedRow() async {
        let h = await opened(3)
        let selected = h.model.visibleRows[1].id
        h.model.select(id: selected)

        h.model.handle(LibraryKeyStroke(.character("k"), .command))

        #expect(h.reported.external.count == 1)
        #expect(h.reported.external.first?.0 == .shortcutAndTrigger)
        #expect(h.reported.external.first?.1 == [selected])
    }

    // Two selected rows: both ids reach the app, so its `ids.count == 1` guard is what keeps the editor shut.
    @Test func commandKWithTwoRowsSelectedPassesBothIds() async {
        let h = await opened(3)
        let first = h.model.visibleRows[0].id
        let second = h.model.visibleRows[1].id
        h.model.select(id: first)
        h.model.toggle(id: second)

        h.model.handle(LibraryKeyStroke(.character("k"), .command))

        #expect(h.reported.external.count == 1)
        #expect(h.reported.external.first?.0 == .shortcutAndTrigger)
        #expect(Set(h.reported.external.first?.1 ?? []) == [first, second])
        #expect(h.reported.external.first?.1.count == 2)
    }

    // Plain K, or ⌘⇧K, is not the editor shortcut.
    @Test func otherKStrokesDoNotRouteToTheEditor() async {
        let h = await opened(2)
        h.model.handle(LibraryKeyStroke(.character("k"), []))
        h.model.handle(LibraryKeyStroke(.character("k"), [.command, .shift]))
        #expect(h.reported.external.filter { $0.0 == .shortcutAndTrigger }.isEmpty)
    }

    // The context-menu entry (LibraryRows) performs the same command through `perform`.
    @Test func performShortcutAndTriggerReachesTheAppWithTheSelection() async {
        let h = await opened(2)
        h.model.perform(.external(.shortcutAndTrigger))
        #expect(h.reported.external.count == 1)
        #expect(h.reported.external.first?.1 == [h.model.visibleRows[0].id])
    }
}
