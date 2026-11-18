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
    @ObservationIgnored private let organizer: LibraryOrganizer?

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
        preferences: any LibraryPreferences, effects: LibraryEffects = LibraryEffects(),
        organizer: LibraryOrganizer? = nil
    ) {
        self.source = source
        self.paster = paster
        self.host = host
        self.preferences = preferences
        self.effects = effects
        self.organizer = organizer
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
            isAccessibilityTrusted: effects.isAccessibilityTrusted(), sort: sort)
    }

    /// The active sort, for the header's sort menu (FR-004-12).
    public var activeSort: LibrarySort { sort }

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

    /// What a finished first-page load does with the selection.
    private enum SelectionPolicy {
        /// Select the first row (open, search, filter).
        case reset
        /// Keep these rows selected where they are still listed; fall back to the first row when none are.
        case keep(Set<UUID>)
    }

    /// Reloads the list after an Organize command changed it (storage publishes `.itemsChanged`, but this model does not
    /// subscribe to it). The scroll position stays. `selecting` names the rows to select afterwards; nil keeps the
    /// current selection. Rows no longer listed drop out of it (FR-004-13).
    public func refresh(selecting ids: [UUID]? = nil) async {
        startReload(interval: nil, selection: .keep(ids.map(Set.init) ?? selection))
        await loadTask?.value
    }

    /// The row to select once `ids` are deleted: the first remaining row after the last deleted one in list order, else
    /// the last remaining row before it, else nil (FR-004-09).
    public static func selectionAfterDeleting(_ ids: Set<UUID>, in rows: [ItemRow]) -> UUID? {
        DeleteConfirmation.selectionAfter(deleting: ids, in: rows)
    }

    /// ⌘S (FR-004-12): the next sort, remembered, list back at its top.
    public func cycleSort() {
        sort = sort.next
        preferences.sort = sort
        scrollResetToken += 1
        startReload(interval: nil)
    }

    private func startReload(interval: PerfInterval?, selection policy: SelectionPolicy = .reset) {
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
            applyFirstPage(page, counts: counts, selection: policy)
        }
    }

    private func applyFirstPage(
        _ page: FlotsamResult<ItemPage>, counts: FlotsamResult<SidebarCounts>, selection policy: SelectionPolicy
    ) {
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
            switch policy {
            case .reset: visibleLimit = Self.rowsPerStep
            case .keep: visibleLimit = max(Self.rowsPerStep, min(visibleLimit, page.rows.count))
            }
            loadState = .loaded
            applySelection(policy, rows: page.rows)
            refreshPreview()
        }
    }

    private func applySelection(_ policy: SelectionPolicy, rows: [ItemRow]) {
        var kept: Set<UUID> = []
        if case .keep(let wanted) = policy { kept = Set(rows.map(\.id)).intersection(wanted) }
        if kept.isEmpty {
            if let first = rows.first {
                selectOnly(first.id)
            } else {
                selection = []
                cursor = nil
                anchor = nil
            }
            return
        }
        // A kept row below the first 50 must be on screen to stay selected.
        if let deepest = rows.lastIndex(where: { kept.contains($0.id) }) { visibleLimit = max(visibleLimit, deepest + 1) }
        selection = kept
        if cursor.map({ !kept.contains($0) }) ?? true { cursor = rows.first { kept.contains($0.id) }?.id }
        if anchor.map({ !kept.contains($0) }) ?? true { anchor = cursor }
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
        guard toLast else { moveCursor(toIndex: 0, extending: false); return }
        guard hasMorePages || isFetchingPage else { selectLastLoadedRow(); return }
        pageInThenSelectLast()
    }

    private func selectLastLoadedRow() {
        visibleLimit = loadedRows.count
        moveCursor(toIndex: visibleRows.count - 1, extending: false)
    }

    /// ⌘↓ means the last item of the whole result, not the last loaded page (FR-003-08): read the remaining storage
    /// pages in order, then select the final row. A newer reload, search or filter change supersedes it, as for `loadMore`.
    private func pageInThenSelectLast() {
        let inFlight = loadTask
        let generation = generation
        loadTask = Task { [weak self] in
            await inFlight?.value
            while let self, generation == self.generation, !Task.isCancelled, hasMorePages {
                isFetchingPage = true
                let query = LibraryQuery(filter: filter, text: searchText, sort: sort, page: loadedPage + 1)
                let result = await source.items(matching: query)
                guard generation == self.generation else { return }
                isFetchingPage = false
                guard !Task.isCancelled else { return }
                switch result {
                case .failure(let error):
                    loadState = .failed(error)
                    return
                case .success(let page):
                    loadedRows += page.rows
                    totalCount = page.totalCount
                    loadedPage = page.page
                    hasMorePages = page.hasMore
                }
            }
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            selectLastLoadedRow()
        }
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
        case .external(.cycleSort): cycleSort()
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

    // MARK: Organize (FRD-004)

    /// Each command runs through the organizer, then refreshes the list on success. A failure is reported by the
    /// organizer and leaves the list as it was (FR-004-14). Nil also when no organizer was supplied.
    private func organize<T>(selecting ids: (T) -> [UUID]? = { _ in nil }, _ action: (LibraryOrganizer) async -> T?) async -> T? {
        guard let organizer, let result = await action(organizer) else { return nil }
        await refresh(selecting: ids(result))
        return result
    }

    /// Pin or unpin the selection: all pinned, or all unpinned (FR-004-01). Returns the state applied.
    public func togglePinSelected() async -> Bool? {
        let ids = Array(selection)
        guard !ids.isEmpty else { return nil }
        return await organize { await $0.togglePin(ids) }
    }

    /// Whether Pin on a context menu opened on row `id` would unpin (FR-004-01): the action covers the selection when the
    /// row is in it, else just the row, and unpins only when every item it covers is pinned (any unpinned one: pin all).
    public func pinActionUnpins(menuRowID id: UUID, isPinned: Bool) -> Bool {
        guard selection.contains(id) else { return isPinned }
        let covered = selectedRows
        return !covered.isEmpty && !PinRule.pinsAll(states: covered.map(\.isPinned))
    }

    /// Tag or untag the selection with an existing tag (FR-004-02). Returns true when the tag was applied.
    public func toggleTagOnSelection(_ tagId: Int64) async -> Bool? {
        let ids = Array(selection)
        guard !ids.isEmpty else { return nil }
        return await organize { await $0.toggleTag(tagId, on: ids) }
    }

    public func createTagOnSelection(name: String, color: TagColor = .default) async -> Int64? {
        let ids = Array(selection)
        return await organize { await $0.createTag(name: name, color: color, applyingTo: ids) }
    }

    public func renameTag(_ tagId: Int64, to name: String) async -> Bool {
        await organize { await $0.renameTag(tagId, to: name) ? true : nil } ?? false
    }

    public func recolorTag(_ tagId: Int64, to color: TagColor) async -> Bool {
        await organize { await $0.recolorTag(tagId, to: color) ? true : nil } ?? false
    }

    /// Removes the tag from every item; the items stay. Returns how many carried it. A list filtered to the tag falls
    /// back to All, since the tag is gone.
    public func deleteTag(_ tagId: Int64) async -> Int? {
        let wasFiltered = filter == .tag(tagId)
        if wasFiltered { filter = .all }
        let removed = await organize { await $0.deleteTag(tagId) }
        if removed == nil, wasFiltered { filter = .tag(tagId) }
        return removed
    }

    public func saveNote(_ note: String?, for id: UUID) async -> Bool {
        await organize { await $0.setNote(note, for: id) ? true : nil } ?? false
    }

    /// The new kind of the edited selected item (FR-004-07); nil when nothing is selected or the edit was rejected.
    public func saveEdit(text: String) async -> ItemKind? {
        guard let id = selectedRow?.id else { return nil }
        return await organize { await $0.editText(id: id, to: text) }
    }

    /// Replaces the selected bundle with its members and selects them (FR-004-11).
    ///
    /// `expecting` is the bundle the user was asked about. A confirmation stays open while the list can still reload,
    /// so at confirm time the selection may no longer be that bundle; then nothing happens, rather than ungrouping a
    /// different bundle the user never confirmed. Nil means "whatever is selected now" (no question was asked).
    public func ungroupSelected(expecting bundle: UUID? = nil) async -> [UUID]? {
        guard let id = selectedRow?.id else { return nil }
        if let bundle, selection != [bundle] { return nil }
        return await organize(selecting: { $0 }) { await $0.ungroup(bundle: id) }
    }

    /// Deletes the selection and selects the row after the last one removed (FR-004-09). The caller confirms first when
    /// `LibraryOrganizer.deleteNeedsConfirmation` says so. `expecting` is the selection the user confirmed: when the
    /// selection has changed since, nothing is deleted (a delete is permanent, FR-004-09). Nil means "the selection
    /// now".
    public func deleteSelected(expecting confirmed: Set<UUID>? = nil) async -> [UUID]? {
        let ids = selection
        guard !ids.isEmpty else { return nil }
        if let confirmed, ids != confirmed { return nil }
        let next = Self.selectionAfterDeleting(ids, in: loadedRows)
        return await organize(selecting: { _ in next.map { [$0] } }) { await $0.delete(Array(ids)) }
    }

    /// How many selected items carry each tag, for the tag menu's all, some or none marks.
    public func tagMembershipOfSelection() async -> [Int64: Int] { await organizer?.tagMembership(of: Array(selection)) ?? [:] }

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
