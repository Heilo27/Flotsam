import Foundation
import Testing
@testable import FlotsamStorage

// TASK-469 / FR-000-05: a bundle row's primary line reads "1 item" at one member and "N items" otherwise.

@Suite struct Plural469BundleCountTests {
    private func line(members: Int) -> String {
        PrimaryLine.text(kind: .bundle, plainText: nil, pixelWidth: nil, pixelHeight: nil, memberCount: members, memberNames: [])
    }

    @Test("FR-000-05 given a bundle of 1, 2 and 7 members, then the row reads '1 item', '2 items', '7 items'",
          arguments: [(1, "1 item"), (2, "2 items"), (7, "7 items")])
    func bundleCount(members: Int, expected: String) {
        // Red if: ui.row.bundleCount loses a plural form.
        #expect(line(members: members) == expected)
    }

    @Test("FR-000-05 given a bundle of 1 member named 'a.txt', then the row reads '1 item · a.txt'")
    func bundleCountWithNames() {
        let text = PrimaryLine.text(kind: .bundle, plainText: nil, pixelWidth: nil, pixelHeight: nil, memberCount: 1, memberNames: ["a.txt"])
        #expect(text == "1 item · a.txt")
    }
}
