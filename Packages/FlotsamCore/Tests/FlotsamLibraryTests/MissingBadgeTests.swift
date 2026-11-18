import FlotsamBase
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-397, FRD-003 FR-003-07: the presentation carries the catalogue's "Missing" badge exactly for missing rows.

@Suite struct MissingBadgeTests {
    private let now = Date(timeIntervalSince1970: 1_000_100)

    @Test("a missing file row carries the Missing badge and speaks it; an existing one carries neither")
    func badge() {
        let missing = makeRow(1, kind: .file, primary: "report.pdf").withMissing(true)
        let present = makeRow(2, kind: .file, primary: "notes.pdf")

        let shown = LibraryRowPresentation(row: missing, position: 0, now: now)
        let plain = LibraryRowPresentation(row: present, position: 1, now: now)

        #expect(shown.isMissing)
        #expect(shown.missingBadge == "Missing")
        #expect(shown.accessibilityLabel.contains("Missing"))
        #expect(!plain.isMissing)
        #expect(plain.missingBadge == nil)
        #expect(!plain.accessibilityLabel.contains("Missing"))
    }
}
