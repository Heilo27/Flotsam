import Foundation
import Testing
@testable import FlotsamBase

// TASK-469 / FR-000-05 (OC-0017): every Settings count string reads "1 item" at one and "N items" otherwise, through the
// catalogue's plural variations. Expected values are literals.

@Suite struct Plural469SettingsCountTests {

    @Test("OC-0017 given a Clear History completion of n items, then the HUD reads '0 items', '1 item', '2 items' deleted",
          arguments: [(0, "0 items deleted"), (1, "1 item deleted"), (2, "2 items deleted"), (1000, "1000 items deleted")])
    func clearDone(count: Int, expected: String) {
        // Red if: ui.settings.clearDone loses its plural variations or SettingsString.text(_:) stops resolving them.
        #expect(SettingsString.clearDone.text([.count(count)]) == expected)
    }

    @Test("FR-000-05 given a Clear History preview of 1 and of 2 items, then the sheet text reads '1 item' and '2 items'",
          arguments: [
            (1, "This permanently deletes 1 item. This can\u{2019}t be undone."),
            (2, "This permanently deletes 2 items. This can\u{2019}t be undone."),
          ])
    func clearCount(count: Int, expected: String) {
        #expect(SettingsString.clearCount.text([.count(count)]) == expected)
    }

    @Test("FR-000-05 given a shorter retention that removes 1 and 2 items, then the confirmation reads '1 item' and '2 items'",
          arguments: [
            (1, "This permanently deletes 1 item older than 30 days. Pinned items and items with a shortcut are kept."),
            (2, "This permanently deletes 2 items older than 30 days. Pinned items and items with a shortcut are kept."),
          ])
    func confirmShorten(count: Int, expected: String) {
        #expect(SettingsString.confirmShorten.text(count: count, label: .retention30Days) == expected)
    }

    @Test("FR-000-05 given a lower image budget that removes 1 and 2 images, then the confirmation reads '1 older image' and '2 older images'",
          arguments: [
            (1, "Lowering the image budget removes 1 older image (500 MB). Pinned and shortcut items are kept."),
            (2, "Lowering the image budget removes 2 older images (500 MB). Pinned and shortcut items are kept."),
          ])
    func confirmBudget(count: Int, expected: String) {
        let size = 500 * 1_048_576
        #expect(SettingsString.confirmBudget.text([.count(count), .byteSize(size)]) == expected)
    }
}
