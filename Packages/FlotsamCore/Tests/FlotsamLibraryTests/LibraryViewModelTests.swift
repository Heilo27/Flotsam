import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

@MainActor
@Suite struct LibraryViewModelTests {
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    private func opened(_ rows: [ItemRow], counts: SidebarCounts? = nil, accessibility: Bool = true) async -> Harness {
        let harness = Harness(rows: rows, counts: counts, accessibility: accessibility)
        await harness.model.open(target: target)
        return harness
    }

    private func key(_ input: LibraryKeyInput, _ modifiers: ChordModifiers = []) -> LibraryKeyStroke {
        LibraryKeyStroke(input, modifiers)
    }

    // MARK: Open state (FR-003-04)

    @Test func openStateIsEmptySearchAllNewestSelectedPreviewClosed() async {
        let h = await opened(Harness.rows(5))
        #expect(h.model.searchText == "")
        #expect(h.model.filter == .all)
        #expect(h.model.selection == [h.model.visibleRows[0].id])
        #expect(!h.model.isPreviewOpen)
        #expect(h.model.loadState == .loaded)
        #expect(h.source.queries.first == LibraryQuery(filter: .all, text: "", sort: .recent, page: 0))
    }

    @Test func reopeningResetsSearchFilterAndPreview() async {
        let h = await opened(Harness.rows(5))
        h.model.setSearchText("item 3")
        await h.model.settled()
        h.model.select(filter: .pinned)
        h.model.perform(.togglePreview)
        await h.model.open(target: target)
        #expect(h.model.searchText == "")
        #expect(h.model.filter == .all)
        #expect(!h.model.isPreviewOpen)
        #expect(h.model.selection == [h.model.visibleRows[0].id])
    }

    @Test func emptyHistoryAndNoResultsAreDifferentStates() async {
        let empty = await opened([])
        #expect(empty.model.isHistoryEmpty)
        #expect(!empty.model.isNoResults)

        let h = await opened(Harness.rows(3))
        h.model.setSearchText("zzz")
        await h.model.settled()
        #expect(h.model.isNoResults)
        #expect(!h.model.isHistoryEmpty)
        #expect(h.model.loadState == .loaded)
    }

    // MARK: Search (FR-003-09, FR-003-10)

    @Test func searchQueriesTheStorageLayerWithTheRawText() async {
        let h = await opened(Harness.rows(30))
        h.model.setSearchText("item 2")
        await h.model.settled()
        #expect(h.source.queries.last?.text == "item 2")
        #expect(h.model.visibleRows.allSatisfy { $0.primaryLine.contains("item 2") })
        #expect(h.model.selection == [h.model.visibleRows[0].id])
    }

    @Test func aSlowEarlierSearchNeverOverwritesALaterOne() async {
        let h = await opened(Harness.rows(30))
        h.source.delays["item 1"] = .milliseconds(300)
        h.model.setSearchText("item 1")
        h.model.setSearchText("item 2")
        await h.model.settled()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(h.model.searchText == "item 2")
        #expect(h.model.visibleRows.allSatisfy { $0.primaryLine.contains("item 2") })
    }

    @Test func storageFailureShowsInlineErrorAndRetryRecovers() async {
        let h = Harness(rows: Harness.rows(3))
        let failure = FlotsamError(.stoDb004, "query failed")
        h.source.failItems = failure
        await h.model.open(target: target)
        #expect(h.model.loadState == .failed(failure))
        #expect(h.reported.errors.isEmpty)
        h.source.failItems = nil
        await h.model.retry()
        #expect(h.model.loadState == .loaded)
        #expect(h.model.visibleRows.count == 3)
    }

    // MARK: Paging (FR-003-05)

    @Test func fiftyRowsShowThenFiftyMorePerStepAcrossStoragePages() async {
        let h = await opened(Harness.rows(450))
        #expect(h.model.visibleRows.count == 50)
        h.model.loadMore()
        #expect(h.model.visibleRows.count == 100)
        h.model.loadMore(); h.model.loadMore(); h.model.loadMore()
        #expect(h.model.visibleRows.count == 200)
        h.model.loadMore()
        await h.model.settled()
        #expect(h.source.queries.last?.page == 1)
        #expect(h.model.visibleRows.count == 250)
        #expect(h.model.totalCount == 450)
    }

    // MARK: Selection and keyboard (FR-003-08)

    @Test func arrowsMoveAndClampAtTheEnds() async {
        let h = await opened(Harness.rows(3))
        let ids = h.model.visibleRows.map(\.id)
        #expect(h.model.handle(key(.up)))
        #expect(h.model.selection == [ids[0]])
        h.model.handle(key(.down)); h.model.handle(key(.down)); h.model.handle(key(.down))
        #expect(h.model.selection == [ids[2]])
    }

    @Test func commandArrowsJumpToFirstAndLast() async {
        let h = await opened(Harness.rows(80))
        h.model.handle(key(.down, .command))
        #expect(h.model.selection == [h.model.loadedRows[79].id])
        h.model.handle(key(.up, .command))
        #expect(h.model.selection == [h.model.loadedRows[0].id])
    }

    @Test func shiftArrowsExtendAndShrinkTheSelection() async {
        let h = await opened(Harness.rows(5))
        let ids = h.model.visibleRows.map(\.id)
        h.model.handle(key(.down, .shift)); h.model.handle(key(.down, .shift))
        #expect(h.model.selection == Set(ids[0...2]))
        h.model.handle(key(.up, .shift))
        #expect(h.model.selection == Set(ids[0...1]))
    }

    @Test func gridArrowsMoveByColumn() async {
        let h = await opened(Harness.rows(20))
        h.model.toggleViewMode()
        h.model.gridColumns = 4
        let ids = h.model.visibleRows.map(\.id)
        h.model.handle(key(.right)); #expect(h.model.selection == [ids[1]])
        h.model.handle(key(.down)); #expect(h.model.selection == [ids[5]])
        h.model.handle(key(.left)); #expect(h.model.selection == [ids[4]])
        h.model.handle(key(.up)); #expect(h.model.selection == [ids[0]])
    }

    @Test func leftRightAreNotHandledInTheList() async {
        let h = await opened(Harness.rows(3))
        #expect(!h.model.handle(key(.left)))
        #expect(!h.model.handle(key(.character("a"))))
    }

    @Test func clickSelectionVariants() async {
        let h = await opened(Harness.rows(6))
        let ids = h.model.visibleRows.map(\.id)
        h.model.select(id: ids[1])
        h.model.toggle(id: ids[3])
        #expect(h.model.selection == [ids[1], ids[3]])
        h.model.select(id: ids[1])
        h.model.extend(to: ids[4])
        #expect(h.model.selection == Set(ids[1...4]))
    }

    @Test func viewModeToggleIsPersisted() async {
        let h = await opened(Harness.rows(1))
        h.model.handle(key(.character("g"), .command))
        #expect(h.model.viewMode == .grid)
        #expect(h.prefs.viewMode == .grid)
        h.model.handle(key(.character("g"), .command))
        #expect(h.prefs.viewMode == .list)
    }

    // MARK: Paste dispatch (FR-003-08, FR-003-15)

    @Test func returnKeysPasteTheSelectedItemInTheRightMode() async {
        let h = await opened(Harness.rows(3))
        let id = h.model.visibleRows[0].id
        for (stroke, mode) in [
            (key(.returnKey), PasteMode.paste), (key(.returnKey, .option), .plainText), (key(.returnKey, .shift), .copyOnly),
        ] {
            h.model.handle(stroke)
            await h.model.pasteTask?.value
            #expect(h.paster.calls.last == FakePaster.Call(itemId: id, mode: mode, target: target))
        }
        #expect(h.paster.calls.count == 3)
    }

    @Test func commandDigitPastesTheNthVisibleRow() async {
        let h = await opened(Harness.rows(12))
        h.model.handle(key(.character("3"), .command))
        await h.model.pasteTask?.value
        #expect(h.paster.calls == [FakePaster.Call(itemId: h.model.visibleRows[2].id, mode: .paste, target: target)])
    }

    @Test func commandDigitBeyondTheRowCountDoesNothing() async {
        let h = await opened(Harness.rows(2))
        h.model.handle(key(.character("5"), .command))
        await h.model.pasteTask?.value
        #expect(h.paster.calls.isEmpty)
    }

    @Test func pasteKeysAreDisabledWithTwoOrMoreSelected() async {
        let h = await opened(Harness.rows(4))
        h.model.handle(key(.down, .shift))
        #expect(h.model.selection.count == 2)
        for stroke in [key(.returnKey), key(.returnKey, .option), key(.returnKey, .shift)] {
            #expect(h.model.handle(stroke))
        }
        await h.model.pasteTask?.value
        #expect(h.paster.calls.isEmpty)
        #expect(h.model.footer().notice == LibraryText.string("ui.library.footerMultiDisabled"))
    }

    @Test func accessibilityDeniedOutcomeReportsTheCopyOnlyFallback() async {
        let h = await opened(Harness.rows(1))
        h.paster.result = .success(.copiedAccessibilityDenied)
        h.model.handle(key(.returnKey))
        await h.model.pasteTask?.value
        #expect(h.reported.errors.map(\.code) == [.setPrm001])
    }

    @Test func aDeletedItemFailureIsReportedAndTheListRefreshes() async {
        let h = await opened(Harness.rows(3))
        h.paster.result = .failure(FlotsamError(.libIo001, "gone"))
        let before = h.source.queries.count
        h.model.handle(key(.returnKey))
        await h.model.pasteTask?.value
        await h.model.settled()
        #expect(h.reported.errors.map(\.code) == [.libIo001])
        #expect(h.source.queries.count > before)
    }

    @Test func aFailedPasteLeavesThePanelOpen() async {
        let h = await opened(Harness.rows(1))
        h.paster.result = .failure(FlotsamError(.libDat001, "files gone"))
        h.model.handle(key(.returnKey))
        await h.model.pasteTask?.value
        #expect(h.host.hideCount == 0)
        #expect(h.reported.errors.map(\.code) == [.libDat001])
    }

    // MARK: Esc ladder, preview, sidebar

    @Test func escapeClearsSearchThenClosesPreviewThenClosesPanel() async {
        let h = await opened(Harness.rows(5))
        h.model.setSearchText("item")
        h.model.perform(.togglePreview)
        #expect(h.model.isPreviewOpen)
        h.model.handle(key(.escape))
        #expect(h.model.searchText == "")
        #expect(h.model.isPreviewOpen)
        #expect(h.host.hideCount == 0)
        h.model.handle(key(.escape))
        #expect(!h.model.isPreviewOpen)
        #expect(h.host.hideCount == 0)
        h.model.handle(key(.escape))
        #expect(h.host.hideCount == 1)
    }

    @Test func escapeWithSeveralSelectedFallsBackToOneBeforeClosing() async {
        let h = await opened(Harness.rows(4))
        h.model.handle(key(.down, .shift))
        h.model.handle(key(.escape))
        #expect(h.model.selection.count == 1)
        #expect(h.host.hideCount == 0)
        h.model.handle(key(.escape))
        #expect(h.host.hideCount == 1)
    }

    @Test func spaceOpensPreviewAndLoadsContent() async {
        let h = await opened(Harness.rows(2))
        h.source.content = ItemContent(kind: .text, plainText: String(repeating: "a", count: 25_000), representations: [], members: [])
        h.model.handle(key(.space))
        await h.model.awaitPreview()
        #expect(h.model.preview?.isTruncated == true)
        #expect(h.model.preview?.text(showingAll: false)?.count == LibraryPreview.textLimit)
        #expect(h.model.preview?.text(showingAll: true)?.count == 25_000)
    }

    @Test func previewDoesNotOpenForAMultiSelection() async {
        let h = await opened(Harness.rows(3))
        h.model.handle(key(.down, .shift))
        h.model.perform(.togglePreview)
        await h.model.awaitPreview()
        #expect(h.model.preview == nil)
    }

    @Test func optionArrowsStepThroughSidebarFilters() async {
        let counts = SidebarCounts(
            all: 5, pinned: 1, kinds: [.text: 4, .link: 1],
            tags: [SidebarCounts.TagCount(id: 7, name: "Work", color: nil, count: 2)], apps: [])
        let h = await opened(Harness.rows(5), counts: counts)
        h.model.handle(key(.down, .option))
        #expect(h.model.filter == .pinned)
        h.model.handle(key(.down, .option))
        #expect(h.model.filter == .kind(.text))
        h.model.handle(key(.up, .option)); h.model.handle(key(.up, .option)); h.model.handle(key(.up, .option))
        #expect(h.model.filter == .all)
        await h.model.settled()
        #expect(h.source.queries.last?.filter == .all)
    }

    @Test func otherFeatureKeysAreHandedOnWithTheSelection() async {
        let h = await opened(Harness.rows(2))
        h.model.handle(key(.character("p"), .command))
        #expect(h.reported.external.count == 1)
        #expect(h.reported.external.first?.0 == .pin)
        #expect(h.reported.external.first?.1 == [h.model.visibleRows[0].id])
        h.model.handle(key(.character(","), .command))
        #expect(h.reported.settingsOpened == 1)
    }

    @Test func revealPassesTheItemsFilePaths() async {
        let h = await opened(Harness.rows(1))
        h.source.content = ItemContent(
            kind: .file, plainText: nil, representations: [],
            members: [ItemMember(path: "/tmp/a.txt", bookmark: nil, isDirectory: false)])
        h.model.handle(key(.character("r"), .command))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.reported.revealed == [["/tmp/a.txt"]])
    }

    @Test func hidingReleasesStorageMemory() async {
        let h = await opened(Harness.rows(1))
        h.model.panelDidHide()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.source.releaseCount == 1)
    }
}
