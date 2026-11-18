import Foundation
import Testing
import FlotsamBase
import FlotsamStorage
@testable import FlotsamShelf

@Suite struct ShelfPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("OC-6045 a 5-line, 300-character text shows its first 3 lines, at most 120 characters, with the text icon")
    func textCardShowsThreeLinesUpToOneHundredTwentyCharacters() {
        // Three short lines, then two long ones: 300 characters over 5 lines, where the line limit binds first.
        let lines = ["L1" + String(repeating: "a", count: 18), "L2" + String(repeating: "b", count: 18),
                     "L3" + String(repeating: "c", count: 18), "L4" + String(repeating: "d", count: 118),
                     "L5" + String(repeating: "e", count: 118)]
        let full = lines.joined(separator: "\n")
        #expect(full.count == 304)
        // The row's primary line is already cut to two lines by the query layer; the card must still show three.
        let row = makeShelfRow(0, kind: .text, primary: lines.prefix(2).joined(separator: "\n"))
        let card = ShelfCardPresentation(row: row, text: full, now: now)
        #expect(card.visual == .kindIcon(.text))
        let shown = card.text ?? ""
        #expect(shown.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
        #expect(shown.count <= ShelfLayout.cardTextCharacterLimit)
        #expect(shown == lines.prefix(3).joined(separator: "\n"))
        #expect(shown.contains("L3"))
        #expect(!shown.contains("L4"))
    }

    @Test("OC-6045 when 3 lines exceed 120 characters the character limit cuts first")
    func characterLimitBindsBeforeTheLineLimit() {
        let line = String(repeating: "z", count: 60)
        let card = ShelfCardPresentation(row: makeShelfRow(0), text: [line, line, line].joined(separator: "\n"), now: now)
        #expect(card.text?.count == 120)
        #expect(card.text == String([line, line, line].joined(separator: "\n").prefix(120)))
    }

    @Test("OC-6045 a short 3-line text is shown whole, and a long single line is cut at 120")
    func textCardBoundaries() {
        let three = ShelfCardPresentation(row: makeShelfRow(0), text: "a\nb\nc\nd", now: now)
        #expect(three.text == "a\nb\nc")
        let oneLong = ShelfCardPresentation(row: makeShelfRow(0), text: String(repeating: "y", count: 121), now: now)
        #expect(oneLong.text?.count == 120)
        let exact = ShelfCardPresentation(row: makeShelfRow(0), text: String(repeating: "y", count: 120), now: now)
        #expect(exact.text?.count == 120)
    }

    @Test("OC-6046 per-kind content: thumbnails, link text, colour swatch and value, file icons, stacked bundle, one pin badge")
    func cardsByKind() {
        let rows = [
            makeShelfRow(1, kind: .image, primary: "Image 10 × 10"),
            makeShelfRow(2, kind: .screenshot, primary: "Screenshot 10 × 10"),
            makeShelfRow(3, kind: .link, primary: "https://example.com", pinned: true),
            makeShelfRow(4, kind: .color, primary: "#FF8800"),
            makeShelfRow(5, kind: .file, primary: "report.pdf"),
            makeShelfRow(6, kind: .folder, primary: "Photos"),
            makeShelfRow(7, kind: .bundle, primary: "3 items · a, b", memberCount: 3),
        ]
        let cards = rows.map { ShelfCardPresentation(row: $0, now: now) }
        #expect(cards[0].visual == .thumbnail && cards[0].text == nil)
        #expect(cards[1].visual == .thumbnail && cards[1].text == nil)
        #expect(cards[2].visual == .kindIcon(.link) && cards[2].text == "https://example.com")
        #expect(cards[3].visual == .swatch && cards[3].text == "#FF8800")
        #expect(cards[4].visual == .fileIcon && cards[5].visual == .fileIcon)
        #expect(cards[6].visual == .stackedIcon(memberCount: 3))
        #expect(cards.filter(\.isPinned).map(\.id) == [rows[2].id])
        #expect(cards.allSatisfy { $0.sourceName == "Notes" })
    }

    @Test("OC-6047 a card shows neither the note, the tag nor a timestamp")
    func cardHidesNotesTagsAndTimestamps() {
        let row = makeShelfRow(0, kind: .text, primary: "plain", tags: ["tt-marker"], copiedAt: now.addingTimeInterval(-7200))
        // Notes are not part of the joined row at all; a tag is, and must not surface.
        let card = ShelfCardPresentation(row: row, text: "plain", now: now)
        let shown = [card.text, card.sourceName].compactMap { $0 }
        #expect(shown == ["plain", "Notes"])
        #expect(!shown.joined().contains("tt-marker"))
        let relative = ItemSpeech.relativeTime(row.lastCopiedAt, now: now)
        #expect(!relative.isEmpty)
        #expect(!shown.joined().contains(relative))
        #expect(!card.accessibilityLabel.contains("tt-marker"))
    }

    @Test("OC-6120 a card's VoiceOver label is the Library's form, with Paste, Copy and Pin and no Drag")
    func voiceOverLabelAndActions() {
        let row = makeShelfRow(0, kind: .text, primary: "hello", source: "Notes", pinned: false, copiedAt: now)
        let card = ShelfCardPresentation(row: row, now: now)
        #expect(card.accessibilityLabel == "Text, hello, from Notes, now")
        #expect(card.accessibilityActions.map(card.title(of:)) == ["Paste", "Copy", "Pin"])
        #expect(!card.accessibilityActions.map(card.title(of:)).contains("Drag"))

        let pinned = ShelfCardPresentation(row: makeShelfRow(1, primary: "hello", source: "Notes", pinned: true, copiedAt: now), now: now)
        #expect(pinned.accessibilityLabel == "Text, hello, from Notes, now, Pinned")
        #expect(pinned.title(of: .togglePin) == "Unpin")

        let long = ShelfCardPresentation(row: makeShelfRow(2, primary: String(repeating: "x", count: 300)), now: now)
        #expect(long.accessibilityLabel.components(separatedBy: ", ")[1].count == 100)
    }
}
