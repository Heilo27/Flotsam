import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-433 blind verify (Worf, worf-433b). FR-003-22 / OC-3091 / OC-3092 (context menu), FR-003-21 / OC-3086 (spoken
// 'pinned'), FR-003-07 / OC-3021 (row metrics). Expected values are literals written from the FRD, not the builder's model.

@Suite struct Worf433bTests {
    private static let sep = "-"

    private func titles(_ kind: ItemKind, pin: Bool = false, single: Bool = true) -> [String] {
        LibraryContextMenu.entries(kind: kind, pinUnpins: pin, singleTarget: single).map { entry in
            switch entry {
            case .separator: Self.sep
            case .item(let key, _, _): LibraryText.string(key)
            }
        }
    }

    private let head = ["Paste", "Paste as Plain Text", "Copy", "Preview", "-"]

    // Red if any kind's order, separator count or Reveal placement changes. Every kind, written out.
    @Test("OC-3091 W433-M1 full menu for every one of the eleven kinds, single target")
    func everyKindExactMenu() {
        // given the eleven kinds; when the menu is built for a single target; then each equals the FR-003-22 order
        let textual = head + ["Pin", "Tags…", "Note…", "Edit…", "Shortcut and Trigger…", "-", "Delete"]
        let noEdit = head + ["Pin", "Tags…", "Note…", "Shortcut and Trigger…", "-", "Delete"]
        let file = head + ["Pin", "Tags…", "Note…", "Shortcut and Trigger…", "-", "Reveal in Finder", "-", "Delete"]
        let bundle = head + ["Pin", "Tags…", "Note…", "Shortcut and Trigger…", "Ungroup", "-", "Reveal in Finder", "-", "Delete"]
        #expect(titles(.text) == textual)
        #expect(titles(.richText) == textual)
        #expect(titles(.link) == textual)
        #expect(titles(.color) == textual)
        #expect(titles(.phone) == textual)
        #expect(titles(.email) == textual)
        #expect(titles(.image) == noEdit)
        #expect(titles(.screenshot) == noEdit)
        #expect(titles(.file) == file)
        #expect(titles(.folder) == file)
        #expect(titles(.bundle) == bundle)
    }

    // Red if a multi-selection menu keeps Note/Edit/Ungroup or loses a separator.
    @Test("OC-3091 W433-M2 multi-item target: no Note, Edit or Ungroup, separators intact, for file and text kinds")
    func multiTargetExact() {
        #expect(titles(.text, single: false) == head + ["Pin", "Tags…", "Shortcut and Trigger…", "-", "Delete"])
        #expect(titles(.bundle, single: false) == head + ["Pin", "Tags…", "Shortcut and Trigger…", "-", "Reveal in Finder", "-", "Delete"])
    }

    // Red if an item is wired to the wrong action (Plain Text pastes rich, Copy pastes, Reveal does nothing).
    @Test("FR-003-22 W433-M3 each entry fires the command of its FR-003-08 key")
    func commandWiring() {
        // given a bundle menu; when the commands are read in order; then each is the key's command and Delete is destructive
        let entries = LibraryContextMenu.entries(kind: .bundle, pinUnpins: false, singleTarget: true)
        let commands: [LibraryCommand?] = entries.map { if case .item(_, let c, _) = $0 { c } else { nil } }
        #expect(commands == [
            .paste(.paste), .paste(.plainText), .paste(.copyOnly), .togglePreview, nil,
            .external(.pin), .external(.tags), .external(.note), .external(.shortcutAndTrigger), .external(.ungroup), nil,
            .revealInFinder, nil,
            .external(.delete),
        ])
        let flags: [Bool] = entries.compactMap { if case .item(_, _, let d) = $0 { d } else { nil } }
        #expect(flags.filter { $0 }.count == 1 && flags.last == true)
    }

    // Red if Unpin stops replacing Pin, or if both show, or if Unpin keeps the Pin command.
    @Test("OC-3092 W433-M4 a pinned target shows Unpin in the same slot as Pin, never both")
    func unpinSlot() {
        let pinned = titles(.file, pin: true)
        let plain = titles(.file, pin: false)
        #expect(pinned.count == plain.count)
        #expect(pinned.firstIndex(of: "Unpin") == plain.firstIndex(of: "Pin"))
        #expect(!pinned.contains("Pin") && !plain.contains("Unpin"))
    }

    // Red if Reveal in Finder is offered for a kind with no file on disk, or dropped for a file kind.
    @Test("FR-003-22 W433-M5 Reveal in Finder appears for exactly file, folder and bundle")
    func revealKinds() {
        let withReveal = ItemKind.allCases.filter { titles($0).contains("Reveal in Finder") }
        #expect(Set(withReveal) == [.file, .folder, .bundle] && withReveal.count == 3)
    }

    // Red if the spoken pinned word reverts to the capitalised badge string, or an unpinned row speaks it.
    @Test("OC-3086 W433-M6 a pinned row reads '..., pinned' lower case and last; an unpinned row has no pin word")
    func spokenPinnedLabel() {
        // given a pinned and an unpinned text row; when the VoiceOver label is built; then literal expected text
        let now = Date(timeIntervalSince1970: 1_000_100)
        let pinned = ItemSpeech.label(for: makeRow(1, primary: "Hello", source: "Safari", pinned: true), now: now)
        let plain = ItemSpeech.label(for: makeRow(2, primary: "Hello", source: "Safari", pinned: false), now: now)
        #expect(pinned.hasSuffix(", pinned") && !pinned.contains("Pinned"))
        #expect(pinned == plain + ", pinned")
        #expect(!plain.lowercased().contains("pinned"))
    }

    // Red if the sidebar/section 'Pinned' string and the spoken word get merged back into one key.
    @Test("OC-3086 W433-M7 the capitalised Pinned badge strings are untouched by the spoken-word change")
    func capitalisedPinnedStays() {
        #expect(LibraryText.string("ui.library.pinned") == "Pinned")
        #expect(LibraryText.string("ui.library.sidebarPinned") == "Pinned")
        #expect(LibraryText.string("ui.library.spokenPinned") == "pinned")
    }

    // Red if the list row stops being a 44 pt hit target or the lead slot grows past the row.
    @Test("OC-3021 W433-M8 list row 44 pt, lead 32 pt, lead fits inside the row with room for padding")
    func rowMetrics() {
        #expect(LibraryLayout.listRowHeight == 44 && LibraryLayout.listLeadSize == 32)
        #expect(LibraryLayout.listLeadSize < LibraryLayout.listRowHeight)
    }
}
