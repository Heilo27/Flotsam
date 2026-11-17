import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation

/// The Library panel's state and behaviour (FRD-003): search, filter, selection, keyboard commands, paste dispatch and
/// the preview. No AppKit or SwiftUI; the panel in `App/Flotsam` renders it and forwards keys to `handle(_:)`.
///
/// `host` is held strongly. The panel controller owns this model and this model owns its host, a deliberate cycle
/// that lives as long as the one panel instance does (FR-003-01).
@MainActor
@Observable
public final class LibraryViewModel {
    public enum LoadState: Equatable {
        case loading, loaded
        /// STO-DB-004: shown inline with Retry (FR-003-20), never as a HUD.
        case failed(FlotsamError)
    }

    /// Rows held in memory on open and added per scroll step (FR-003-05).
    public static let rowsPerStep = 50

    // MARK: Observable state

    public private(set) var loadState: LoadState = .loading
    public private(set) var loadedRows: [ItemRow] = []
    public private(set) var totalCount = 0
    public private(set) var visibleLimit = LibraryViewModel.rowsPerStep
    public private(set) var searchText = ""
    public private(set) var filter: LibraryFilter = .all
    public private(set) var sidebar: SidebarCounts?
    public private(set) var selection: Set<UUID> = []
    public private(set) var isPreviewOpen = false
    public private(set) var preview: LibraryPreview?
    public private(set) var viewMode: LibraryViewMode
    /// Incremented whenever the list is reset to its top (open, new search, new filter), so the view scrolls there.
    public private(set) var scrollResetToken = 0
    /// Set by the grid view so ↑/↓ move by a row of cells.
    public var gridColumns = 1

    // MARK: Collaborators

    @ObservationIgnored private let source: any LibraryDataSource
    @ObservationIgnored private let paster: any PastePerforming
    @ObservationIgnored private let host: any PasteHost
    @ObservationIgnored private let preferences: any LibraryPreferences
    @ObservationIgnored private let effects: LibraryEffects

    // MARK: Private state

    @ObservationIgnored private var sort: LibrarySort
    @ObservationIgnored private var cursor: UUID?
    @ObservationIgnored private var anchor: UUID?
    @ObservationIgnored private var target: FrontmostApp?
    @ObservationIgnored private var loadedPage = 0
    @ObservationIgnored private var hasMorePages = false
    @ObservationIgnored private var generation = 0
    /// A next storage page is in flight; scrolling calls `loadMore` repeatedly and must not fetch the page twice.
    @ObservationIgnored private var isFetchingPage = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// The latest paste, kept so tests (and a future cancel) can await it.
    @ObservationIgnored public private(set) var pasteTask: Task<Void, Never>?

    public init(
        source: any LibraryDataSource, paster: any PastePerforming, host: any PasteHost,
        preferences: any LibraryPreferences, effects: LibraryEffects = LibraryEffects()
    ) {
        self.source = source
        self.paster = paster
        self.host = host
        self.preferences = preferences
        self.effects = effects
        viewMode = preferences.viewMode
        sort = preferences.sort
    }

    // MARK: Derived

    /// The rows on screen: the newest `visibleLimit` of what is loaded (FR-003-05).
    public var visibleRows: [ItemRow] { Array(loadedRows.prefix(visibleLimit)) }

    public var sidebarEntries: [SidebarEntry] { sidebar.map(SidebarEntry.entries(from:)) ?? [] }

    /// Selected rows in list order.
    public var selectedRows: [ItemRow] { visibleRows.filter { selection.contains($0.id) } }

    public var selectedRow: ItemRow? { selection.count == 1 ? selectedRows.first : nil }

    public var cursorID: UUID? { cursor }

    public func footer(now: Date = Date()) -> LibraryFooter {
        LibraryFooter(
            totalCount: totalCount, selectionCount: selection.count, isPreviewOpen: isPreviewOpen,
            isAccessibilityTrusted: effects.isAccessibilityTrusted())
    }

    public func rowPresentations(now: Date = Date()) -> [LibraryRowPresentation] {
        visibleRows.enumerated().map { LibraryRowPresentation(row: $1, position: $0, now: now) }
    }

    /// The empty history state, as opposed to "no matches" (FR-003-11): nothing stored at all.
    public var isHistoryEmpty: Bool { loadState == .loaded && loadedRows.isEmpty && searchText.isEmpty && filter == .all }

    public var isNoResults: Bool { loadState == .loaded && loadedRows.isEmpty && !isHistoryEmpty }

    // MARK: Lifecycle

    /// The panel is about to show (FR-003-04): empty search, All, newest selected, top of the list, preview closed.
    /// `target` is the app that was frontmost before the panel, recorded by the caller (FR-003-02).
    public func open(target: FrontmostApp?) async {
        self.target = target
        searchText = ""
        filter = .all
        isPreviewOpen = false
        preview = nil
        selection = []
        cursor = nil
        anchor = nil
        viewMode = preferences.viewMode
        sort = preferences.sort
        scrollResetToken += 1
        startReload(interval: .libraryOpen)
        await loadTask?.value
    }

    /// The panel hid, for any reason: drop in-flight work and let storage free what only a visible panel needs
    /// (FR-003-13).
    public func panelDidHide() {
        loadTask?.cancel()
        previewTask?.cancel()
        generation += 1
        let source = source
        Task { await source.releaseMemory() }
    }

    public func retry() async {
        startReload(interval: nil)
        await loadTask?.value
    }

    // MARK: Search and filter

    public func setSearchText(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        scrollResetToken += 1
        startReload(interval: text.isEmpty ? nil : .librarySearch)
    }

    /// Awaits the load a search started; tests and the open path use it, the view does not need to.
    public func settled() async { await loadTask?.value }

    public func select(filter newFilter: LibraryFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        scrollResetToken += 1
        startReload(interval: nil)
    }

    private func startReload(interval: PerfInterval?) {
        loadTask?.cancel()
        generation += 1
        isFetchingPage = false
        let generation = generation
        let query = LibraryQuery(filter: filter, text: searchText, sort: sort, page: 0)
        if loadedRows.isEmpty { loadState = .loading }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let span = interval.map { Signposts.begin($0) }
            async let pageResult = source.items(matching: query)
            async let countsResult = source.sidebarCounts()
            let (page, counts) = await (pageResult, countsResult)
            span?.end()
            guard !Task.isCancelled, generation == self.generation else { return }
            applyFirstPage(page, counts: counts)
        }
    }

    private func applyFirstPage(_ page: FlotsamResult<ItemPage>, counts: FlotsamResult<SidebarCounts>) {
        if case .success(let counts) = counts { sidebar = counts }
        switch page {
        case .failure(let error):
            // The previous rows stay on screen; the inline error offers Retry (FR-003-20).
            loadState = .failed(error)
        case .success(let page):
            loadedRows = page.rows
            totalCount = page.totalCount
            loadedPage = page.page
            hasMorePages = page.hasMore
            visibleLimit = Self.rowsPerStep
            loadState = .loaded
            if let first = page.rows.first {
                selectOnly(first.id)
            } else {
                selection = []
                cursor = nil
                anchor = nil
            }
            refreshPreview()
        }
    }

    /// Shows 50 more rows, fetching the next storage page when the loaded ones run out (FR-003-05).
    public func loadMore() {
        if visibleLimit < loadedRows.count {
            visibleLimit = min(visibleLimit + Self.rowsPerStep, loadedRows.count)
            return
        }
        guard hasMorePages, loadState == .loaded, !isFetchingPage else { return }
        isFetchingPage = true
        let generation = generation
        let query = LibraryQuery(filter: filter, text: searchText, sort: sort, page: loadedPage + 1)
        loadTask = Task { [weak self] in
            guard let self else { return }
            let result = await source.items(matching: query)
            guard generation == self.generation else { return }
            isFetchingPage = false
            guard !Task.isCancelled else { return }
            switch result {
            case .failure(let error): loadState = .failed(error)
            case .success(let page):
                loadedRows += page.rows
                totalCount = page.totalCount
                loadedPage = page.page
                hasMorePages = page.hasMore
                visibleLimit = min(visibleLimit + Self.rowsPerStep, loadedRows.count)
            }
        }
    }

    // MARK: Selection

    public func select(id: UUID) { selectOnly(id); refreshPreview() }

    /// ⌘-click: add or remove one row.
    public func toggle(id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        cursor = id
        anchor = id
        refreshPreview()
    }

    /// ⇧-click: everything between the anchor and `id`.
    public func extend(to id: UUID) {
        guard let anchorID = anchor ?? cursor else { select(id: id); return }
        selectRange(from: anchorID, to: id)
        cursor = id
        refreshPreview()
    }

    private func selectOnly(_ id: UUID) {
        selection = [id]
        cursor = id
        anchor = id
    }

    private func selectRange(from: UUID, to: UUID) {
        let rows = visibleRows
        guard let a = rows.firstIndex(where: { $0.id == from }), let b = rows.firstIndex(where: { $0.id == to }) else { return }
        selection = Set(rows[min(a, b)...max(a, b)].map(\.id))
    }

    private func cursorIndex() -> Int? {
        guard let cursor else { return nil }
        return visibleRows.firstIndex { $0.id == cursor }
    }

    private func move(_ direction: LibraryDirection, extending: Bool) {
        guard !loadedRows.isEmpty else { return }
        let columns = viewMode == .grid ? max(1, gridColumns) : 1
        let delta: Int
        switch direction {
        case .up: delta = -columns
        case .down: delta = columns
        case .left: delta = -1
        case .right: delta = 1
        }
        let current = cursorIndex() ?? 0
        var next = current + delta
        // Moving past the last visible row reveals the next 50 first, so ↓ never stops at the page edge.
        if next >= visibleLimit { loadMore() }
        next = min(max(next, 0), visibleRows.count - 1)
        moveCursor(toIndex: next, extending: extending)
    }

    private func moveCursor(toIndex index: Int, extending: Bool) {
        let rows = visibleRows
        guard rows.indices.contains(index) else { return }
        let id = rows[index].id
        if extending, let anchorID = anchor ?? cursor {
            selectRange(from: anchorID, to: id)
            cursor = id
        } else {
            selectOnly(id)
        }
        refreshPreview()
    }

    private func jump(toLast: Bool) {
        guard !loadedRows.isEmpty else { return }
        if toLast { visibleLimit = loadedRows.count }
        moveCursor(toIndex: toLast ? visibleRows.count - 1 : 0, extending: false)
    }

    // MARK: Keyboard

    /// Resolves and runs a key. False means the Library does not own the key and it belongs to the search field
    /// (FR-003-08).
    @discardableResult
    public func handle(_ stroke: LibraryKeyStroke) -> Bool {
        let context = LibraryKeyMap.Context(searchIsEmpty: searchText.isEmpty, viewMode: viewMode)
        guard let command = LibraryKeyMap.command(for: stroke, in: context) else { return false }
        perform(command)
        return true
    }

    public func perform(_ command: LibraryCommand) {
        switch command {
        case .move(let direction): move(direction, extending: false)
        case .extend(let direction): move(direction, extending: true)
        case .jumpToFirst: jump(toLast: false)
        case .jumpToLast: jump(toLast: true)
        case .paste(let mode): pasteSelected(mode: mode)
        case .pasteRow(let number): pasteRow(number)
        case .togglePreview: setPreviewOpen(!isPreviewOpen)
        case .escape: escape()
        case .previousFilter: stepFilter(by: -1)
        case .nextFilter: stepFilter(by: 1)
        case .toggleViewMode: toggleViewMode()
        case .revealInFinder: reveal()
        case .openSettings: effects.openSettings()
        case .external(let command): effects.external(command, selectedRows.map(\.id))
        }
    }

    /// The Esc ladder (FR-003-08): clear the search, then close the preview, then (with several rows selected) fall back
    /// to one, then close the panel. The selection step is DESIGN's "clear selection"; see the FRD note in the commit.
    private func escape() {
        if !searchText.isEmpty { setSearchText(String()); return }
        if isPreviewOpen { setPreviewOpen(false); return }
        if selection.count > 1, let cursor { select(id: cursor); return }
        host.hidePanel()
    }

    public func toggleViewMode() {
        viewMode = viewMode == .list ? .grid : .list
        preferences.viewMode = viewMode
    }

    private func stepFilter(by delta: Int) {
        let entries = sidebarEntries
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.filter == filter } ?? 0
        select(filter: entries[min(max(current + delta, 0), entries.count - 1)].filter)
    }

    // MARK: Paste

    private func pasteSelected(mode: PasteMode) {
        // With two or more rows selected the paste keys are disabled and the footer says so (FR-003-08).
        guard let row = selectedRow else { return }
        startPaste(of: row.id, mode: mode)
    }

    private func pasteRow(_ number: Int) {
        let rows = visibleRows
        guard (1...9).contains(number), rows.count >= number else { return }
        let row = rows[number - 1]
        selectOnly(row.id)
        startPaste(of: row.id, mode: .paste)
    }

    private func startPaste(of id: UUID, mode: PasteMode) {
        pasteTask = Task { await paste(itemId: id, mode: mode) }
    }

    /// Runs the paste sequence and turns its outcome into what the user sees. A paste failure never closes the panel
    /// itself: `PasteService` hides it on success only (FR-003-15).
    public func paste(itemId: UUID, mode: PasteMode) async {
        let result = await paster.paste(itemId: itemId, mode: mode, target: target, host: host)
        switch result {
        case .success(.pasted), .success(.copied):
            break
        case .success(.copiedAccessibilityDenied):
            effects.report(FlotsamError(.setPrm001, "paste copied only: Accessibility not granted", context: [.itemId: .id(itemId)]))
        case .failure(let error):
            effects.report(error)
            // The item vanished under the panel (LIB-IO-001 deletes it): refresh so the row goes.
            if error.code == .libIo001 { startReload(interval: nil) }
        }
    }

    // MARK: Preview

    private func setPreviewOpen(_ open: Bool) {
        isPreviewOpen = open
        if open { refreshPreview() } else { previewTask?.cancel(); preview = nil }
    }

    private func refreshPreview() {
        previewTask?.cancel()
        guard isPreviewOpen, let row = selectedRow else { preview = nil; return }
        previewTask = Task { [weak self] in
            guard let self else { return }
            let source = source
            let content = await source.content(of: row.id)
            let image = row.kind == .image || row.kind == .screenshot ? await source.thumbnail(itemId: row.id, size: .preview) : nil
            guard !Task.isCancelled, selectedRow?.id == row.id else { return }
            switch content {
            case .success(let content): preview = LibraryPreview(row: row, content: content, imageData: image)
            case .failure(let error): preview = nil; effects.report(error)
            }
        }
    }

    public func awaitPreview() async { await previewTask?.value }

    // MARK: Reveal and thumbnails

    private func reveal() {
        guard let row = selectedRow else { return }
        Task { [weak self] in
            guard let self else { return }
            switch await source.content(of: row.id) {
            case .success(let content):
                let paths = content.members.map(\.path)
                if !paths.isEmpty { effects.reveal(paths) }
            case .failure(let error):
                effects.report(error)
            }
        }
    }

    public func thumbnail(for id: UUID, size: ThumbnailSize) async -> Data? {
        await source.thumbnail(itemId: id, size: size)
    }
}
