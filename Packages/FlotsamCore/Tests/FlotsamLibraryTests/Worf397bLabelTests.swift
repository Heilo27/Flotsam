import FlotsamBase
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-397 follow-up (Worf, worf-397b), ruling (e): after the merge with main the spoken label still ends with the
// pinned word and then "Missing", in that order, and is built from ItemSpeech (kind, text, source, time, pinned).

@Suite struct Worf397bLabelTests {
    private let now = Date(timeIntervalSince1970: 1_000_100)

    private func label(_ row: ItemRow) -> String { LibraryRowPresentation(row: row, position: 0, now: now).accessibilityLabel }

    // Red if Missing moves before the pinned word, replaces ItemSpeech, or the pinned word is dropped for missing rows.
    @Test("OC-397b-L1 pinned + missing label ends with 'pinned, Missing' in that order after the item's own text")
    func pinnedThenMissing() {
        let plain = makeRow(1, kind: .file, primary: "report.pdf", pinned: true)
        let missing = plain.withMissing(true)

        let spokenPlain = label(plain)
        let spokenMissing = label(missing)

        #expect(spokenPlain.hasSuffix(", pinned"))
        #expect(spokenMissing == spokenPlain + ", Missing")
        #expect(spokenMissing.hasSuffix(", pinned, Missing"))
        #expect(spokenMissing.contains("report.pdf"))
        #expect(spokenMissing.components(separatedBy: "Missing").count == 2)
    }

    // Red if the Missing word is appended to rows that are not missing, or a stray separator is left behind.
    @Test("OC-397b-L2 unpinned missing label ends with ', Missing'; unpinned present and pinned present never say Missing")
    func otherCombinations() {
        let missingOnly = label(makeRow(2, kind: .folder, primary: "Docs").withMissing(true))
        let neither = label(makeRow(3, kind: .folder, primary: "Docs"))
        let pinnedOnly = label(makeRow(4, kind: .folder, primary: "Docs", pinned: true))

        #expect(missingOnly.hasSuffix(", Missing"))
        #expect(!missingOnly.contains("pinned"))
        #expect(!neither.contains("Missing"))
        #expect(!neither.hasSuffix(","))
        #expect(!pinnedOnly.contains("Missing"))
        #expect(pinnedOnly.hasSuffix(", pinned"))
    }

    // Red if the presentation starts deciding Missing by kind (the kind gate lives in storage): flagged rows of every
    // kind show the badge, unflagged rows of every kind do not.
    @Test("OC-397b-L3 the presentation mirrors the row flag for every kind: no kind decides Missing on its own")
    func mirrorsFlag() {
        for kind in ItemKind.allCases {
            let on = LibraryRowPresentation(row: makeRow(5, kind: kind).withMissing(true), position: 0, now: now)
            let off = LibraryRowPresentation(row: makeRow(5, kind: kind), position: 0, now: now)
            #expect(on.isMissing && on.missingBadge == "Missing", "kind \(kind.rawValue) flagged")
            #expect(!off.isMissing && off.missingBadge == nil, "kind \(kind.rawValue) unflagged")
        }
    }
}
