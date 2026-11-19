import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-498 blind QA (Worf), FR-003-23 / AC-003-19, FR-004-07, FR-005-09: a secure item's menu offers neither Edit nor
// Shortcut and Trigger, the organizer refuses Edit, and the preview shows the mask even if the content somehow carries
// text. Expected lists and strings are literals from the spec; each test names the change that turns it red.

@MainActor
@Suite struct Worf498SecureLibraryTests {
    private let mask = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"

    private func row(secure: Bool, unavailable: Bool = false, kind: ItemKind = .text) -> ItemRow {
        ItemRow(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000498")!, kind: kind,
            lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_000), pasteCount: 0,
            primaryLine: secure ? (unavailable ? "Unavailable" : "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}") : "ordinary",
            sourceName: "1Password", tagNames: [], isPinned: false, hasTrigger: false, hasShortcut: false, pixelWidth: nil,
            pixelHeight: nil, memberCount: 0, byteSize: 0, isSecure: secure, isUnavailable: unavailable)
    }

    private func titles(secure: Bool, single: Bool) -> [String] {
        LibraryContextMenu.entries(kind: .text, pinUnpins: false, singleTarget: single, isSecure: secure).map { entry in
            switch entry {
            case .separator: "-"
            case .item(let key, _, _): LibraryText.string(key)
            }
        }
    }

    // Red if `!isSecure` is dropped from the Edit condition (Edit appears for a secure item) or from the Shortcut and
    // Trigger condition (a hotkey or trigger could be offered for something that can carry neither).
    @Test("FR-003-23 W498-L1: a secure text item's menu has neither Edit nor Shortcut and Trigger")
    func secureMenuLacksEditAndShortcut() {
        #expect(titles(secure: true, single: true) == [
            "Paste", "Paste as Plain Text", "Copy", "Preview", "-", "Pin", "Tags…", "Note…", "-", "Delete",
        ])
        #expect(titles(secure: true, single: false) == [
            "Paste", "Paste as Plain Text", "Copy", "Preview", "-", "Pin", "Tags…", "-", "Delete",
        ])
    }

    // Control: the identical call for an ordinary text item still has both entries, so the secure list above is a real
    // removal and not a menu that never had them.
    @Test("FR-003-22 W498-L2: an ordinary text item's menu still has Edit and Shortcut and Trigger")
    func ordinaryMenuKeepsThem() {
        let ordinary = titles(secure: false, single: true)
        #expect(ordinary.contains("Edit…"))
        #expect(ordinary.contains("Shortcut and Trigger…"))
        #expect(ordinary.count == 12)
    }

    // Red if `!rows[0].isSecure` is dropped from `canEdit`.
    @Test("FR-004-07 W498-L3: Edit is refused for a secure item and allowed for an ordinary one")
    func organizerRefusesEditForSecure() {
        #expect(!LibraryOrganizer.canEdit([row(secure: true)]))
        #expect(LibraryOrganizer.canEdit([row(secure: false)]))
    }

    // Red if the preview reads `content.plainText` for a secure row.
    @Test("AC-003-19 W498-L4: the preview of a secure item shows the mask and none of the content's text, even when it has some")
    func previewShowsTheMask() {
        let content = ItemContent(
            kind: .text, plainText: "hunter2-LEAK", representations: [], members: [], firstCopiedAt: nil, copyCount: 1, note: nil, tags: [])

        let preview = LibraryPreview(row: row(secure: true), content: content, imageData: nil)

        #expect(preview.text(showingAll: true) == mask)
        #expect(preview.text(showingAll: false) == mask)
        #expect(preview.text(showingAll: true)?.contains("hunter2") == false)
    }

    @Test("AC-003-19 W498-L5: the preview of an unavailable secure item says Unavailable, and an ordinary item still previews its text")
    func previewUnavailableAndControl() {
        let content = ItemContent(
            kind: .text, plainText: "visible text", representations: [], members: [], firstCopiedAt: nil, copyCount: 1, note: nil, tags: [])

        #expect(LibraryPreview(row: row(secure: true, unavailable: true), content: content, imageData: nil).text(showingAll: true) == "Unavailable")
        #expect(LibraryPreview(row: row(secure: false), content: content, imageData: nil).text(showingAll: true) == "visible text")
    }
}
