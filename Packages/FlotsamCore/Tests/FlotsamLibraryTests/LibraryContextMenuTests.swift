import CoreGraphics
import FlotsamBase
import Testing
@testable import FlotsamLibrary

/// TASK-433: FR-003-22 / OC-3091 (menu order and separators) and FR-003-07 / OC-3021 (row metrics). The expected lists are
/// written out from the spec, not derived from the model.
@Suite struct LibraryContextMenuTests {
    private static let sep = "-"

    private func titles(_ kind: ItemKind, pinUnpins: Bool = false, single: Bool = true) -> [String] {
        LibraryContextMenu.entries(kind: kind, pinUnpins: pinUnpins, singleTarget: single).map { entry in
            switch entry {
            case .separator: Self.sep
            case .item(let key, _, _): LibraryText.string(key)
            }
        }
    }

    @Test("OC-3091 text menu: Paste, Paste as Plain Text, Copy, Preview, sep, Pin, Tags, Note, Edit, Shortcut and Trigger, sep, Delete")
    func textMenu() {
        #expect(titles(.text) == [
            "Paste", "Paste as Plain Text", "Copy", "Preview", "-",
            "Pin", "Tags…", "Note…", "Edit…", "Shortcut and Trigger…", "-",
            "Delete",
        ])
    }

    @Test("OC-3091 bundle menu has Ungroup and Reveal in Finder, no Edit; Reveal sits between two separators")
    func bundleMenu() {
        #expect(titles(.bundle) == [
            "Paste", "Paste as Plain Text", "Copy", "Preview", "-",
            "Pin", "Tags…", "Note…", "Shortcut and Trigger…", "Ungroup", "-",
            "Reveal in Finder", "-",
            "Delete",
        ])
    }

    @Test("OC-3091 image menu has neither Edit nor Ungroup")
    func imageMenu() {
        let image = titles(.image)
        #expect(!image.contains("Edit…") && !image.contains("Ungroup"))
        #expect(image.first == "Paste" && image.last == "Delete")
    }

    @Test("FR-003-22 file and folder menus: Reveal in Finder, no Edit, no Ungroup")
    func fileKinds() {
        for kind in [ItemKind.file, .folder] {
            let menu = titles(kind)
            #expect(menu.contains("Reveal in Finder") && !menu.contains("Edit…") && !menu.contains("Ungroup"))
        }
    }

    @Test("FR-003-22 no menu starts or ends with a separator or doubles one, for every kind and selection shape")
    func separatorsNeverLeadTrailOrDouble() {
        for kind in ItemKind.allCases {
            for single in [true, false] {
                let menu = titles(kind, single: single)
                #expect(menu.first != Self.sep && menu.last != Self.sep, "\(kind)")
                #expect(!zip(menu, menu.dropFirst()).contains { $0 == Self.sep && $1 == Self.sep }, "\(kind)")
            }
        }
    }

    @Test("FR-004-01 Pin reads Unpin when the action unpins")
    func pinOrUnpin() {
        #expect(titles(.text, pinUnpins: false).contains("Pin") && !titles(.text, pinUnpins: false).contains("Unpin"))
        #expect(titles(.text, pinUnpins: true).contains("Unpin"))
    }

    @Test("FR-003-22 a multi-item target drops the single-item entries (Note, Edit, Ungroup)")
    func multiTarget() {
        let menu = titles(.bundle, single: false)
        #expect(!menu.contains("Note…") && !menu.contains("Edit…") && !menu.contains("Ungroup"))
        #expect(menu.contains("Pin") && menu.contains("Delete"))
    }

    @Test("only Delete is destructive")
    func destructive() {
        let destructive = LibraryContextMenu.entries(kind: .text, pinUnpins: false, singleTarget: true).compactMap { entry -> LibraryCommand? in
            if case .item(_, let command, true) = entry { command } else { nil }
        }
        #expect(destructive == [.external(.delete)])
    }

    @Test("OC-3021 a list row is 44 pt tall with a 32 pt lead slot")
    func rowMetrics() {
        #expect(LibraryLayout.listRowHeight == 44)
        #expect(LibraryLayout.listLeadSize == 32)
    }

    @Test("VoiceOver pinned word is lower case (OC-3086)")
    func spokenPinnedLowercase() {
        #expect(LibraryText.string("ui.library.spokenPinned") == "pinned")
        #expect(LibraryText.string("ui.library.pinned") == "Pinned")
    }
}
