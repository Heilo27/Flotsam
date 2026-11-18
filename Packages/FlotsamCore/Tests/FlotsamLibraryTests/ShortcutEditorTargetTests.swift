import Foundation
import Testing
@testable import FlotsamLibrary

/// The guard behind ⌘K and the "Shortcut and Trigger..." context-menu row (FR-005-09, TASK-317 condition): the editor
/// opens for exactly one selected item and for no other command.
@Suite struct ShortcutEditorTargetTests {
    private let first = UUID()
    private let second = UUID()

    @Test func oneSelectedRowOpensTheEditorForIt() {
        #expect(LibraryExternalCommand.shortcutAndTrigger.shortcutEditorTarget(selection: [first]) == first)
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
}
