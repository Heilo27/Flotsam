import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-469 / FR-000-05: the Library footer and the delete confirmation use catalogue plural variations. Literals.

@Suite struct Plural469LibraryCountTests {

    @Test("FR-000-05 given a footer count of 0, 1, 2 and 12, then it reads '0 items', '1 item', '2 items', '12 items'",
          arguments: [(0, "0 items"), (1, "1 item"), (2, "2 items"), (12, "12 items")])
    func footer(count: Int, expected: String) {
        // Red if: ui.library.footerItems loses a plural form, or the footer branches on a second key again.
        #expect(LibraryText.itemCount(count) == expected)
    }

    @Test("FR-004-09 given a delete of 2 and of 50 items, then the confirmation names the count with 'items'",
          arguments: [(2, "Delete 2 items permanently? This cannot be undone."), (50, "Delete 50 items permanently? This cannot be undone.")])
    func deleteMany(count: Int, expected: String) {
        #expect(LibraryText.confirmDelete(count: count) == expected)
    }

    @Test("FR-004-09 given a delete of exactly 1 item, then the confirmation reads 'this item', never '1 items'")
    func deleteOne() {
        let text = LibraryText.confirmDelete(count: 1)
        #expect(text == "Delete this item permanently? This cannot be undone.")
        #expect(!text.contains("1 items"))
    }
}
