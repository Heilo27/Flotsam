import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-467 / FR-004-04 (OC-4030, OC-4031): the delete-tag confirmation copy is pluralised through the catalogue and the
// "ask first?" decision has one home, LibraryOrganizer.deleteTagNeedsConfirmation. Expected values are literals.

@Suite struct Worf467DeleteTagConfirmationTests {

    @Test("OC-4030 given a tag on 1 item, when the delete confirmation is built, then it reads '1 item', never '1 items'")
    func singularAtOne() {
        // Red if: the catalogue plural variant is reverted to a plain "%lld items" string, or the "one" form is dropped.
        let text = LibraryText.confirmDeleteTag(name: "Work", itemCount: 1)
        #expect(text == "Remove tag 'Work' from 1 item?")
        #expect(!text.contains("1 items"))
    }

    @Test("OC-4030 given a tag on 2 items, when the delete confirmation is built, then it reads '2 items'")
    func pluralAtTwo() {
        // Red if: the "other" form is dropped or the count stops being substituted.
        #expect(LibraryText.confirmDeleteTag(name: "Work", itemCount: 2) == "Remove tag 'Work' from 2 items?")
    }

    @Test("OC-4030 given tags on 5 and 11 items, when the confirmation is built, then the plural form carries the full count")
    func pluralCarriesLargerCounts() {
        // Red if: the plural rule picks the wrong form for counts above 2 or truncates the number.
        #expect(LibraryText.confirmDeleteTag(name: "A", itemCount: 5) == "Remove tag 'A' from 5 items?")
        #expect(LibraryText.confirmDeleteTag(name: "A", itemCount: 11) == "Remove tag 'A' from 11 items?")
    }

    @Test("OC-4031 given item counts at and around the threshold, when asked whether to confirm, then only counts of 1 or more ask")
    func thresholdBoundary() {
        // Red if: the comparison is flipped (< 0, <= 0, == 0), moved to >= 0 / > 1, or negative counts start asking.
        #expect(LibraryOrganizer.deleteTagNeedsConfirmation(itemCount: -1) == false)
        #expect(LibraryOrganizer.deleteTagNeedsConfirmation(itemCount: 0) == false)
        #expect(LibraryOrganizer.deleteTagNeedsConfirmation(itemCount: 1) == true)
        #expect(LibraryOrganizer.deleteTagNeedsConfirmation(itemCount: 2) == true)
        #expect(LibraryOrganizer.deleteTagNeedsConfirmation(itemCount: Int.max) == true)
    }

    @Test("OC-4031 given the App's OrganizeCoordinator source, when scanned, then deleteTag asks through the seam and holds no inline copy of the rule")
    func coordinatorKeepsNoInlineRule() throws {
        // The App target has no test target, so the wiring is checked at source level (Rule 9: one home for the rule).
        // Red if: deleteTag stops calling LibraryOrganizer.deleteTagNeedsConfirmation, or re-inlines an itemCount comparison.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Flotsam/Library/OrganizeCoordinator.swift"), encoding: .utf8)
        // control: the right function body was found
        let start = try #require(source.range(of: "func deleteTag(id: Int64"))
        let body = String(source[start.lowerBound...].prefix(600))
        #expect(body.contains("LibraryText.confirmDeleteTag"))
        // then
        #expect(body.contains("LibraryOrganizer.deleteTagNeedsConfirmation(itemCount: itemCount)"))
        for inline in ["itemCount > 0", "itemCount >= 1", "itemCount != 0", "itemCount == 0", "itemCount < 1", "itemCount <= 0"] {
            #expect(!body.contains(inline), "inline copy of the delete-tag rule: \(inline)")
        }
    }
}
