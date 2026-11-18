import FlotsamBase
import FlotsamStorage
import Foundation

/// A section of the Shelf (FR-006-06).
public struct ShelfSection: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case pinned, recent }

    public let kind: Kind
    public let titleKey: String
    public let cards: [ShelfCardPresentation]

    public var id: Kind { kind }
}

public enum ShelfMenuAction: Sendable, Equatable {
    case paste, pastePlain, copy, togglePin, delete
}

/// One line of a card's context menu (FR-006-09).
public enum ShelfMenuEntry: Sendable, Equatable {
    case item(ShelfMenuAction, titleKey: String)
    case separator
}

public enum ShelfLoadState: Sendable, Equatable {
    case idle, loading, loaded
    case failed(FlotsamError)
}

/// The Shelf's state and behaviour (FR-006-06, -08, -09), with no AppKit: the panel and its cards are views over this.
@MainActor
@Observable
public final class ShelfModel {
    // MARK: Observable state

    public private(set) var pinnedRows: [ItemRow] = []
    public private(set) var recentRows: [ItemRow] = []
    public private(set) var selection: Set<UUID> = []
    public private(set) var loadState: ShelfLoadState = .idle
    /// A sticky Shelf may become key and takes keys; a transient one does not (FR-006-08).
    public private(set) var isSticky = false
    public private(set) var isOpen = false
    /// A drag that the Shelf would accept is over the panel: the drop zone is highlighted (FR-006-12).
    public private(set) var isDropTargeted = false
    /// The card a successful drop stored or bumped, highlighted for `ShelfLayout.dropHighlightDuration` and scrolled
    /// into view (FR-006-15). Set by `highlight(_:)`; cleared by `clearHighlight(of:)`.
    public private(set) var highlightedItemId: UUID?

    // MARK: Collaborators

    @ObservationIgnored private let source: any ShelfDataSource
    @ObservationIgnored private let details: any ShelfCardDetails
    @ObservationIgnored private let paster: any ShelfPasting
    @ObservationIgnored private let host: any ShelfPasteHost
    @ObservationIgnored private let events: ItemEventBus
    @ObservationIgnored private let effects: ShelfEffects

    // MARK: Private state

    @ObservationIgnored private var texts: [UUID: String] = [:]
    @ObservationIgnored private var cursor: UUID?
    @ObservationIgnored private var anchor: UUID?
    @ObservationIgnored private var target: FrontmostApp?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var unsubscribe: (@Sendable () -> Void)?
    /// The latest paste and the latest pin or delete, kept so tests can await them.
    @ObservationIgnored public private(set) var pasteTask: Task<Void, Never>?
    @ObservationIgnored public private(set) var actionTask: Task<Void, Never>?

    public init(
        source: any ShelfDataSource, paster: any ShelfPasting, host: any ShelfPasteHost, events: ItemEventBus,
        details: any ShelfCardDetails = NoShelfCardDetails(), effects: ShelfEffects = ShelfEffects()
    ) {
        self.source = source
        self.paster = paster
        self.host = host
        self.events = events
        self.details = details
        self.effects = effects
    }

    // MARK: Derived

    /// The cards in on-screen order: Pinned, then Recent.
    public var orderedRows: [ItemRow] { pinnedRows + recentRows }

    public var isEmpty: Bool { pinnedRows.isEmpty && recentRows.isEmpty }

    public var selectedRows: [ItemRow] { orderedRows.filter { selection.contains($0.id) } }

    public var cursorID: UUID? { cursor }

    /// The sections to draw: a section with no cards is hidden (FR-006-06). With none, the view shows the empty state.
    public func sections() -> [ShelfSection] {
        let now = effects.now()
        func cards(_ rows: [ItemRow]) -> [ShelfCardPresentation] {
            rows.map { ShelfCardPresentation(row: $0, text: texts[$0.id], isMissing: $0.isMissing, now: now) }
        }
        var result: [ShelfSection] = []
        if !pinnedRows.isEmpty {
            result.append(ShelfSection(kind: .pinned, titleKey: ShelfText.sectionPinned, cards: cards(pinnedRows)))
        }
        if !recentRows.isEmpty {
            result.append(ShelfSection(kind: .recent, titleKey: ShelfText.sectionRecent, cards: cards(recentRows)))
        }
        return result
    }

    /// Awaits the load, paste and pin or delete in flight; tests and the open path use it.
    public func settled() async {
        await loadTask?.value
        await pasteTask?.value
        await actionTask?.value
        // A paste or action may have started a reload of its own.
        await loadTask?.value
    }

    // MARK: Open and hide

    /// Opens the Shelf (FR-006-06): flushes capture first so a copy made an instant ago is listed, then reads the
    /// sections and selects the first card (FR-006-08). Live refresh starts here and stops in `didHide`.
    public func open(target: FrontmostApp?, sticky: Bool) async {
        self.target = target
        isSticky = sticky
        isOpen = true
        subscribeIfNeeded()
        await effects.captureNow()
        guard isOpen else { return }
        startReload(selection: .first)
        await loadTask?.value
    }

    /// Hides the panel through the host (Esc, a finished paste hides it the same way) and stops refreshing.
    public func hide() {
        host.hidePanel()
        didHide()
    }

    /// The panel is no longer visible, for any reason (Esc, a paste, a transient timeout): stop listening and drop
    /// in-flight loads. Idempotent, so the platform may call it as well as `hide()`.
    public func didHide() {
        isOpen = false
        isDropTargeted = false
        highlightedItemId = nil
        unsubscribe?()
        unsubscribe = nil
        loadTask?.cancel()
        generation += 1
    }

    private func subscribeIfNeeded() {
        guard unsubscribe == nil else { return }
        // The bus calls handlers inline on the publisher's executor; hop to the main actor before touching state.
        unsubscribe = events.subscribe { [weak self] _ in
            Task { @MainActor [weak self] in self?.storedItemsChanged() }
        }
    }

    private func storedItemsChanged() {
        guard isOpen else { return }
        startReload(selection: .keep(selection))
    }

    // MARK: Loading (FR-006-06)

    private enum SelectionPolicy {
        /// Select the first card (a reveal).
        case first
        /// Keep these cards selected where they are still listed; fall back to the first card when none are.
        case keep(Set<UUID>)
    }

    private func startReload(selection policy: SelectionPolicy) {
        loadTask?.cancel()
        generation += 1
        let generation = generation
        if orderedRows.isEmpty { loadState = .loading }
        let pinnedQuery = LibraryQuery(filter: .pinned, text: "", sort: .recent, page: 0)
        let allQuery = LibraryQuery(filter: .all, text: "", sort: .recent, page: 0)
        loadTask = Task { [weak self] in
            guard let self else { return }
            async let pinnedResult = source.items(matching: pinnedQuery)
            async let allResult = source.items(matching: allQuery)
            let (pinnedPage, allPage) = await (pinnedResult, allResult)
            guard !Task.isCancelled, generation == self.generation else { return }
            switch (pinnedPage, allPage) {
            case (.failure(let error), _), (_, .failure(let error)):
                // The previous cards stay on screen.
                loadState = .failed(error)
                effects.report(error)
            case (.success(let pinned), .success(let all)):
                let limit = ShelfLayout.sectionLimit
                let pinnedRows = Array(pinned.rows.prefix(limit))
                // Recent is the first unfiltered page with pinned items removed (FR-006-06).
                let recentRows = Array(all.rows.filter { !$0.isPinned }.prefix(limit))
                let rows = pinnedRows + recentRows
                let textResult = await details.cardTexts(for: rows.map(\.id))
                guard !Task.isCancelled, generation == self.generation else { return }
                var loadedTexts: [UUID: String] = [:]
                switch textResult {
                case .success(let texts): loadedTexts = texts
                // The cards still show, on their primary line; the failure is reported like the list's own.
                case .failure(let error): effects.report(error)
                }
                apply(pinned: pinnedRows, recent: recentRows, texts: loadedTexts, selection: policy)
            }
        }
    }

    private func apply(pinned: [ItemRow], recent: [ItemRow], texts: [UUID: String], selection policy: SelectionPolicy) {
        pinnedRows = pinned
        recentRows = recent
        self.texts = texts
        loadState = .loaded
        applySelection(policy, rows: pinned + recent)
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
        selection = kept
        if cursor.map({ !kept.contains($0) }) ?? true { cursor = rows.first { kept.contains($0.id) }?.id }
        if anchor.map({ !kept.contains($0) }) ?? true { anchor = cursor }
    }

    // MARK: Keyboard (FR-006-08)

    /// Handles a key; true when the Shelf used it. A transient Shelf, a closed one, and keys outside the map (Space)
    /// return false and change nothing.
    @discardableResult
    public func handle(_ stroke: KeyStroke) -> Bool {
        guard isOpen, let command = ShelfKeyMap.command(for: stroke, isSticky: isSticky) else { return false }
        switch command {
        case .move(let direction): move(direction)
        case .paste(let mode): pasteSelected(mode: mode)
        case .hide: hide()
        }
        return true
    }

    private func move(_ direction: ShelfDirection) {
        let rows = orderedRows
        guard !rows.isEmpty else { return }
        let current = cursor.flatMap { id in rows.firstIndex { $0.id == id } }
        let next: Int
        switch (current, direction) {
        case (nil, _): next = 0
        case (let index?, .previous): next = max(index - 1, 0)
        case (let index?, .next): next = min(index + 1, rows.count - 1)
        }
        selectOnly(rows[next].id)
    }

    // MARK: Mouse (FR-006-09)

    /// A click selects; ⌘-click toggles; ⇧-click extends from the anchor.
    public func click(_ id: UUID, modifiers: ChordModifiers = []) {
        let rows = orderedRows
        guard rows.contains(where: { $0.id == id }) else { return }
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            cursor = id
            anchor = id
        } else if modifiers.contains(.shift), let anchorID = anchor,
            let from = rows.firstIndex(where: { $0.id == anchorID }), let to = rows.firstIndex(where: { $0.id == id })
        {
            selection = Set(rows[min(from, to)...max(from, to)].map(\.id))
            cursor = id
        } else {
            selectOnly(id)
        }
    }

    /// Double-click pastes the card under the pointer, never the whole selection.
    public func doubleClick(_ id: UUID) {
        guard orderedRows.contains(where: { $0.id == id }) else { return }
        selectOnly(id)
        startPaste(of: id, mode: .paste)
    }

    private func selectOnly(_ id: UUID) {
        selection = [id]
        cursor = id
        anchor = id
    }

    // MARK: Context menu (FR-006-09)

    /// The menu for a right-click on card `id`, in order: Paste, Paste as Plain Text, Copy, separator, Pin or Unpin,
    /// separator, Delete. Pin reads Unpin only when every card the action covers is pinned (FR-004-01).
    public func contextMenu(for id: UUID) -> [ShelfMenuEntry] {
        let unpins = !covered(by: id).isEmpty && !PinRule.pinsAll(states: covered(by: id).map(\.isPinned))
        return [
            .item(.paste, titleKey: ShelfText.menuPaste),
            .item(.pastePlain, titleKey: ShelfText.menuPastePlain),
            .item(.copy, titleKey: ShelfText.menuCopy),
            .separator,
            .item(.togglePin, titleKey: unpins ? ShelfText.menuUnpin : ShelfText.menuPin),
            .separator,
            .item(.delete, titleKey: ShelfText.menuDelete),
        ]
    }

    /// Runs a menu action chosen on card `id`. Paste and Copy act on that card; Pin and Delete act on the selection
    /// when the card is in it, else on the card alone.
    public func perform(_ action: ShelfMenuAction, on id: UUID) {
        guard orderedRows.contains(where: { $0.id == id }) else { return }
        switch action {
        case .paste: startPaste(of: id, mode: .paste)
        case .pastePlain: startPaste(of: id, mode: .plainText)
        case .copy: startPaste(of: id, mode: .copyOnly)
        case .togglePin:
            let rows = covered(by: id)
            actionTask = Task { await togglePin(rows) }
        case .delete:
            let rows = covered(by: id)
            actionTask = Task { await delete(rows) }
        }
    }

    public func setDropTargeted(_ targeted: Bool) {
        if isDropTargeted != targeted { isDropTargeted = targeted }
    }

    public func highlight(_ id: UUID) { highlightedItemId = id }

    /// Clears the highlight only when it is still `id`, so a second drop within the 600 ms keeps its own.
    public func clearHighlight(of id: UUID) {
        if highlightedItemId == id { highlightedItemId = nil }
    }

    /// The cards an action on card `id` covers, in on-screen order: the whole selection when the card is in it, else
    /// the card alone. Pin, Delete and drag-out (FR-006-10) all use this one rule.
    public func covered(by id: UUID) -> [ItemRow] {
        if selection.contains(id) { return selectedRows }
        return orderedRows.filter { $0.id == id }
    }

    // MARK: Pin (FR-004-01)

    private func togglePin(_ rows: [ItemRow]) async {
        guard !rows.isEmpty else { return }
        let pin = PinRule.pinsAll(states: rows.map(\.isPinned))
        let result = await source.setPinned(ids: rows.map(\.id), pinned: pin)
        if case .failure(let error) = result { effects.report(error) }
        // Storage publishes `.itemsChanged`, but the pin refreshes the list itself so the card moves at once.
        startReload(selection: .keep(Set(rows.map(\.id))))
        await loadTask?.value
    }

    // MARK: Delete (FR-004-09)

    private func delete(_ rows: [ItemRow]) async {
        guard !rows.isEmpty else { return }
        if DeleteConfirmation.isRequired(for: rows) {
            guard await effects.confirmDelete(DeleteConfirmation.message(count: rows.count)) else { return }
        }
        let ids = Set(rows.map(\.id))
        let next = DeleteConfirmation.selectionAfter(deleting: ids, in: orderedRows)
        let result = await source.delete(ids: Array(ids))
        if case .failure(let error) = result { effects.report(error) }
        startReload(selection: .keep(next.map { [$0] } ?? []))
        await loadTask?.value
    }

    // MARK: Paste (FR-006-08)

    private func pasteSelected(mode: ShelfPasteMode) {
        // Like the Library, paste keys act on exactly one selected card.
        guard selection.count == 1, let row = selectedRows.first else { return }
        startPaste(of: row.id, mode: mode)
    }

    private func startPaste(of id: UUID, mode: ShelfPasteMode) {
        pasteTask = Task { await paste(itemId: id, mode: mode) }
    }

    /// Runs the paste sequence and turns its outcome into what the user sees. A failure never hides the panel itself:
    /// the paste service hides it on success only.
    public func paste(itemId: UUID, mode: ShelfPasteMode) async {
        let result = await paster.paste(itemId: itemId, mode: mode, target: target, host: host)
        switch result {
        case .success(.pasted), .success(.copied):
            break
        case .success(.copiedAccessibilityDenied):
            effects.report(FlotsamError(.setPrm001, "paste copied only: Accessibility not granted", context: [.itemId: .id(itemId)]))
        case .failure(let error):
            effects.report(error)
            // The item vanished under the panel (LIB-IO-001 deletes it): refresh so the card goes.
            if error.code == .libIo001 { startReload(selection: .keep(selection)) }
        }
    }
}
