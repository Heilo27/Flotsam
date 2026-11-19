import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

@Suite struct LibraryPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000 + 120)

    @Test func firstNineRowsGetACommandNumberBadge() {
        let badges = (0..<11).map { LibraryRowPresentation(row: makeRow($0), position: $0, now: now).shortcutBadge }
        #expect(badges.prefix(9).map { $0 ?? "" } == (1...9).map { "⌘\($0)" })
        #expect(badges[9] == nil && badges[10] == nil)
    }

    @Test func threeTagChipsThenAPlusCount() {
        let row = makeRow(0, tags: ["a", "b", "c", "d", "e"])
        let presentation = LibraryRowPresentation(row: row, position: 0, now: now)
        #expect(presentation.tagChips == ["a", "b", "c"])
        #expect(presentation.tagOverflow == "+2")
        #expect(LibraryRowPresentation(row: makeRow(0, tags: ["a", "b", "c"]), position: 0, now: now).tagOverflow == nil)
    }

    @Test func secondaryLineIsSourceThenRelativeTime() {
        let presentation = LibraryRowPresentation(row: makeRow(0, source: "Safari"), position: 0, now: now)
        #expect(presentation.secondaryText.hasPrefix("Safari · "))
        let noSource = LibraryRowPresentation(row: makeRow(0, source: nil), position: 0, now: now)
        #expect(!noSource.secondaryText.contains("·"))
    }

    @Test func voiceOverLabelFollowsTheSpecAndCapsThePrimaryLine() {
        let long = String(repeating: "x", count: 300)
        let presentation = LibraryRowPresentation(row: makeRow(0, primary: long, source: "Notes", pinned: true), position: 0, now: now)
        let parts = presentation.accessibilityLabel.components(separatedBy: ", ")
        #expect(parts[0] == KindLabel.text(for: .text))
        #expect(parts[1].count == LibraryRowPresentation.accessibilityPrimaryLimit)
        #expect(parts[2] == "from Notes")
        #expect(parts.last == "pinned")
    }

    @Test func aFutureCopyTimeReadsAsNowNotInTheFuture() {
        let future = makeRow(0, copiedAt: now.addingTimeInterval(3600))
        let presentation = LibraryRowPresentation(row: future, position: 0, now: now)
        #expect(!presentation.secondaryText.lowercased().contains("in "))
    }

    @Test func sidebarOrdersSectionsAndHidesEmptyTypes() {
        let counts = SidebarCounts(
            all: 10, pinned: 0, kinds: [.link: 3, .text: 7, .image: 0],
            tags: [SidebarCounts.TagCount(id: 1, name: "Idle", color: nil, count: 0)],
            apps: [SidebarCounts.AppCount(identity: .anotherDevice, name: nil, count: 2)])
        let entries = SidebarEntry.entries(from: counts)
        #expect(entries.map(\.filter) == [.all, .pinned, .kind(.text), .kind(.link), .tag(1), .sourceApp(.anotherDevice)])
        #expect(entries.first { $0.filter == .tag(1) }?.isDimmed == true)
        #expect(entries.first { $0.filter == .kind(.text) }?.title == "Text")
        #expect(entries.first { $0.filter == .kind(.link) }?.title == "Links")
    }

    @Test func footerShowsThreeHintsAndTheCount() {
        let footer = LibraryFooter(totalCount: 12, selectionCount: 1, isPreviewOpen: false, isAccessibilityTrusted: true, sort: .recent)
        #expect(footer.hints.count == 3)
        #expect(footer.countText == "12 items")
        #expect(footer.notice == nil)
        #expect(LibraryFooter(totalCount: 1, selectionCount: 1, isPreviewOpen: false, isAccessibilityTrusted: true, sort: .recent).countText == "1 item")
    }

    /// FR-004-12: the footer names the active sort, for every sort, in every footer state.
    @Test(arguments: [(LibrarySort.recent, "Recent"), (.oldest, "Oldest"), (.mostUsed, "Most Used"), (.alphabetical, "A to Z")])
    func footerNamesTheActiveSort(sort: LibrarySort, name: String) {
        #expect(LibrarySort.allCases.count == 4)
        for trusted in [true, false] {
            for selection in [1, 3] {
                let footer = LibraryFooter(totalCount: 5, selectionCount: selection, isPreviewOpen: false, isAccessibilityTrusted: trusted, sort: sort)
                #expect(footer.sortName == name)
            }
        }
    }

    @Test func footerShowsTheCopyOnlyNoticeWithoutAccessibility() {
        let footer = LibraryFooter(totalCount: 3, selectionCount: 1, isPreviewOpen: true, isAccessibilityTrusted: false, sort: .recent)
        #expect(footer.notice == "Press ⌘V to paste")
        #expect(footer.hints.contains { $0.label == "Close" })
    }

    /// FR-003-18 / TASK-507: the copy-only hint names ⌘C while Accessibility is denied; trusted keeps ⌥Return Plain text.
    @Test func footerSecondHintIsCommandCCopyWhenUntrustedAndPlainTextWhenTrusted() {
        for preview in [false, true] {
            let untrusted = LibraryFooter(totalCount: 3, selectionCount: 1, isPreviewOpen: preview, isAccessibilityTrusted: false, sort: .recent)
            #expect(untrusted.hints.count == 3)
            #expect(untrusted.hints[1] == LibraryFooter.Hint(key: "⌘C", label: "Copy"), "preview \(preview)")
            let trusted = LibraryFooter(totalCount: 3, selectionCount: 1, isPreviewOpen: preview, isAccessibilityTrusted: true, sort: .recent)
            #expect(trusted.hints.count == 3)
            #expect(trusted.hints[1] == LibraryFooter.Hint(key: "⌥Return", label: "Plain text"), "preview \(preview)")
        }
    }

    /// FR-003-18 / FR-003-08 / TASK-507 (Worf). given two or more rows selected with Accessibility denied, then the footer offers
    /// only "Esc Clear selection": no ⌘C hint (copy is disabled with several rows), and the copy-only notice stays replaced
    /// by the multi-select notice. Red if the ⌘C hint leaks into the multi-select branch.
    @Test func footerMultiSelectUntrustedOffersNoCommandCHint() {
        for selected in [2, 3] {
            let footer = LibraryFooter(totalCount: 5, selectionCount: selected, isPreviewOpen: false, isAccessibilityTrusted: false, sort: .recent)
            #expect(footer.hints == [LibraryFooter.Hint(key: "Esc", label: "Clear selection")], "selected \(selected)")
            #expect(footer.notice == "Select one item to paste", "selected \(selected)")
        }
    }

    @Test func footerForAMultiSelectionCountsAndDisablesPaste() {
        let footer = LibraryFooter(totalCount: 30, selectionCount: 3, isPreviewOpen: false, isAccessibilityTrusted: true, sort: .recent)
        #expect(footer.countText == "3 selected")
        #expect(footer.notice == "Select one item to paste")
    }

    @Test func noResultsTitleQuotesTheQuery() {
        #expect(LibraryText.noResultsTitle(query: "foo") == "No matches for “foo”")
    }
}
