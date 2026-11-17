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
        #expect(parts.last == "Pinned")
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

    @Test func footerShowsTheCopyOnlyNoticeWithoutAccessibility() {
        let footer = LibraryFooter(totalCount: 3, selectionCount: 1, isPreviewOpen: true, isAccessibilityTrusted: false, sort: .recent)
        #expect(footer.notice == "Press ⌘V to paste")
        #expect(footer.hints.contains { $0.label == "Close" })
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
