import Foundation
import Testing
@testable import FlotsamLibrary

/// The guard behind ⌘K and the "Shortcut and Trigger..." context-menu row (FR-005-09, TASK-317 condition, TASK-526): the
/// editor opens for exactly one selected item that can carry a shortcut, and for no other command.
@Suite struct ShortcutEditorTargetTests {
    private let first = makeRow(1)
    private let second = makeRow(2)

    @Test func oneSelectedRowOpensTheEditorForIt() {
        #expect(LibraryExternalCommand.shortcutAndTrigger.shortcutEditorTarget(selection: [first]) == first.id)
    }

    @Test func noSelectionOpensNothing() {
        #expect(LibraryExternalCommand.shortcutAndTrigger.shortcutEditorTarget(selection: []) == nil)
    }

    @Test func severalSelectedRowsOpenNothing() {
        #expect(LibraryExternalCommand.shortcutAndTrigger.shortcutEditorTarget(selection: [first, second]) == nil)
    }

    @Test func everyOtherExternalCommandOpensNothing() {
        let others: [LibraryExternalCommand] = [.pin, .tags, .note, .edit, .delete, .cycleSort, .ungroup]
        for command in others { #expect(command.shortcutEditorTarget(selection: [first]) == nil) }
    }

    // TASK-526: a secure item carries no hotkey or trigger (FRD-001 FR-001-25), so the editor does not open for it.
    // Red if `ShortcutEditorRule.allows` stops refusing a secure item.
    @Test func aSecureRowOpensNothing() {
        let secure = makeRow(3, secure: true)
        #expect(LibraryExternalCommand.shortcutAndTrigger.shortcutEditorTarget(selection: [secure]) == nil)
    }
}
