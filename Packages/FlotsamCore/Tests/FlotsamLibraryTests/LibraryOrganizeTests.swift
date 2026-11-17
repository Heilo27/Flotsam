import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

/// A scripted Organize store: deletes and pins edit the same rows `FakeSource` serves, so a refresh shows the result.
final class FakeOrganizeStore: LibraryOrganizeStore, @unchecked Sendable {
    private let lock = NSLock()
    private let source: FakeSource
    private var _calls: [String] = []
    var failure: FlotsamError?

    init(source: FakeSource) { self.source = source }

    var calls: [String] { lock.withLock { _calls } }

    private func record<T>(_ call: String, _ value: T) -> FlotsamResult<T> {
        lock.withLock { _calls.append(call) }
        if let failure { return .failure(failure) }
        return .success(value)
    }

    func togglePinned(ids: [UUID]) async -> FlotsamResult<Bool> { record("pin \(ids.count)", true) }
    func createTagAndApply(name: String, color: TagColor, to ids: [UUID]) async -> FlotsamResult<Int64> { record("createTag \(name)", 7) }
    func toggleTag(id: Int64, on ids: [UUID]) async -> FlotsamResult<Bool> { record("toggleTag \(id)", true) }
    func renameTag(id: Int64, to name: String) async -> FlotsamResult<Bool> { record("renameTag \(id)", true) }
    func recolorTag(id: Int64, to color: TagColor) async -> FlotsamResult<Bool> { record("recolorTag \(id)", true) }
    func deleteTag(id: Int64) async -> FlotsamResult<Int> { record("deleteTag \(id)", 3) }
    func tagMembership(of ids: [UUID]) async -> FlotsamResult<[Int64: Int]> { record("membership", [1: ids.count]) }
    func setNote(_ note: String?, for id: UUID) async -> FlotsamResult<Bool> { record("note \(note ?? "nil")", true) }
    func note(of id: UUID) async -> FlotsamResult<String?> { record("noteOf", nil) }
    func editText(id: UUID, to text: String, classifiers: ItemClassifiers) async -> FlotsamResult<ItemKind?> { record("edit \(text)", .text) }
    func ungroup(bundle: UUID, classifiers: ItemClassifiers) async -> FlotsamResult<[UUID]> { record("ungroup", []) }

    func delete(ids: [UUID]) async -> FlotsamResult<[UUID]> {
        let result = record("delete \(ids.count)", ids)
        if case .success = result { source.rows.removeAll { ids.contains($0.id) } }
        return result
    }
}

@MainActor
@Suite struct LibraryOrganizeTests {
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)
    private let classifiers = ItemClassifiers(
        editedText: { ItemClassification(kind: .text, contentKey: $0) }, fileMember: { path, _ in ItemClassification(kind: .file, contentKey: path) })

    private struct Rig {
        let harness: Harness
        let store: FakeOrganizeStore
        var model: LibraryViewModel { harness.model }
    }

    /// A model over `count` rows with an organizer attached, opened.
    private func rig(_ count: Int) async -> Rig {
        let source = FakeSource(rows: Harness.rows(count))
        let store = FakeOrganizeStore(source: source)
        let reported = Harness.Reported()
        let prefs = FakePreferences()
        let organizer = LibraryOrganizer(store: store, classifiers: classifiers, report: { reported.errors.append($0) })
        let host = FakeHost()
        let model = LibraryViewModel(
            source: source, paster: FakePaster(), host: host, preferences: prefs,
            effects: LibraryEffects(report: { reported.errors.append($0) }), organizer: organizer)
        let harness = Harness(model: model, source: source, prefs: prefs, reported: reported)
        await model.open(target: target)
        return Rig(harness: harness, store: store)
    }

    // MARK: Sort (FR-004-12)

    @Test func commandSCyclesRecentOldestMostUsedAlphabeticalThenBack() async {
        let r = await rig(3)
        for _ in 0..<4 {
            r.model.perform(.external(.cycleSort))
            await r.model.settled()
        }
        #expect(r.harness.source.queries.map(\.sort) == [.recent, .oldest, .mostUsed, .alphabetical, .recent])
        #expect(r.harness.reported.external.isEmpty)
    }

    @Test func theSortIsRememberedAndNamedInTheFooter() async {
        let r = await rig(3)
        #expect(r.model.footer().sortName == "Recent")
        r.model.cycleSort()
        await r.model.settled()
        #expect(r.harness.prefs.sort == .oldest)
        #expect(r.model.footer().sortName == "Oldest")
        r.model.cycleSort()
        #expect(r.model.footer().sortName == "Most Used")
        r.model.cycleSort()
        #expect(r.model.footer().sortName == "A to Z")
    }

    @Test func openingUsesTheRememberedSortAndCyclingScrollsToTheTop() async {
        let r = await rig(3)
        r.harness.prefs.sort = .alphabetical
        await r.model.open(target: target)
        #expect(r.harness.source.queries.last?.sort == .alphabetical)
        let token = r.model.scrollResetToken
        r.model.cycleSort()
        #expect(r.model.scrollResetToken == token + 1)
        #expect(r.harness.prefs.sort == .recent)
    }

    // MARK: Selection after delete (FR-004-09)

    @Test func selectionMovesToTheRowAfterTheLastDeleted() {
        let rows = Harness.rows(6)
        func after(_ deleted: [Int]) -> UUID? {
            LibraryViewModel.selectionAfterDeleting(Set(deleted.map { rows[$0].id }), in: rows)
        }
        #expect(after([2]) == rows[3].id)
        #expect(after([1, 2]) == rows[3].id)
        #expect(after([0, 4]) == rows[5].id)
        #expect(after([5]) == rows[4].id)
        #expect(after([4, 5]) == rows[3].id)
        #expect(after([0, 1, 2, 3, 4, 5]) == nil)
        #expect(after([]) == nil)
    }

    @Test func deletingSelectsTheNextRowAndDropsTheDeletedOnes() async {
        let r = await rig(5)
        let rows = r.model.visibleRows
        r.model.select(id: rows[1].id)
        r.model.toggle(id: rows[2].id)
        let removed = await r.model.deleteSelected()
        #expect(Set(removed ?? []) == [rows[1].id, rows[2].id])
        #expect(r.store.calls == ["delete 2"])
        #expect(r.model.visibleRows.map(\.id) == [rows[0].id, rows[3].id, rows[4].id])
        #expect(r.model.selection == [rows[3].id])
        #expect(r.model.cursorID == rows[3].id)
        #expect(r.model.totalCount == 3)
    }

    @Test func deletingEverythingLeavesNothingSelected() async {
        let r = await rig(2)
        r.model.select(id: r.model.visibleRows[0].id)
        r.model.toggle(id: r.model.visibleRows[1].id)
        _ = await r.model.deleteSelected()
        #expect(r.model.selection.isEmpty)
        #expect(r.model.cursorID == nil)
    }

    // MARK: Refresh (FR-004-13)

    @Test func refreshKeepsTheSelectionCursorAndScrollPosition() async {
        let r = await rig(8)
        let rows = r.model.visibleRows
        r.model.select(id: rows[2].id)
        r.model.extend(to: rows[4].id)
        let token = r.model.scrollResetToken
        let queries = r.harness.source.queries.count
        await r.model.refresh()
        #expect(r.harness.source.queries.count == queries + 1)
        #expect(r.model.selection == Set(rows[2...4].map(\.id)))
        #expect(r.model.cursorID == rows[4].id)
        #expect(r.model.scrollResetToken == token)
    }

    @Test func refreshDropsRowsThatNoLongerExistAndFallsBackToTheFirstRow() async {
        let r = await rig(4)
        let rows = r.model.visibleRows
        r.model.select(id: rows[1].id)
        r.model.toggle(id: rows[2].id)
        r.harness.source.rows.removeAll { $0.id == rows[1].id }
        await r.model.refresh()
        #expect(r.model.selection == [rows[2].id])
        r.harness.source.rows.removeAll { $0.id == rows[2].id }
        await r.model.refresh()
        #expect(r.model.selection == [rows[0].id])
    }

    @Test func refreshSelectingNamedRowsSelectsThoseOnly() async {
        let r = await rig(5)
        let rows = r.model.visibleRows
        await r.model.refresh(selecting: [rows[3].id, rows[4].id])
        #expect(r.model.selection == [rows[3].id, rows[4].id])
        #expect(r.model.cursorID == rows[3].id)
    }

    // MARK: Commands refresh the list

    @Test func everyOrganizeCommandRefreshesOnSuccess() async {
        let r = await rig(3)
        let id = r.model.visibleRows[0].id
        func queries() -> Int { r.harness.source.queries.count }
        var before = queries()
        #expect(await r.model.togglePinSelected() == true)
        #expect(queries() == before + 1); before = queries()
        #expect(await r.model.toggleTagOnSelection(1) == true)
        #expect(queries() == before + 1); before = queries()
        #expect(await r.model.createTagOnSelection(name: "Work") == 7)
        #expect(queries() == before + 1); before = queries()
        #expect(await r.model.renameTag(1, to: "Home"))
        #expect(await r.model.recolorTag(1, to: .red))
        #expect(await r.model.saveNote("hi", for: id))
        #expect(await r.model.saveEdit(text: "new") == .text)
        #expect(queries() == before + 4)
        #expect(r.store.calls == ["pin 1", "toggleTag 1", "createTag Work", "renameTag 1", "recolorTag 1", "note hi", "edit new"])
    }

    @Test func aFailedCommandIsReportedOnceAndTheListIsLeftAlone() async {
        let r = await rig(3)
        r.store.failure = FlotsamError(.stoDb001, "write failed")
        let before = r.harness.source.queries.count
        let selection = r.model.selection
        #expect(await r.model.togglePinSelected() == nil)
        #expect(await r.model.deleteSelected() == nil)
        #expect(r.harness.reported.errors.map(\.code) == [.stoDb001, .stoDb001])
        #expect(r.harness.source.queries.count == before)
        #expect(r.model.selection == selection)
    }

    @Test func deletingTheFilteredTagFallsBackToAll() async {
        let r = await rig(3)
        r.model.select(filter: .tag(5))
        await r.model.settled()
        #expect(await r.model.deleteTag(5) == 3)
        #expect(r.model.filter == .all)
        #expect(r.harness.source.queries.last?.filter == .all)
    }

    @Test func aFailedTagDeleteKeepsTheFilter() async {
        let r = await rig(3)
        r.model.select(filter: .tag(5))
        await r.model.settled()
        r.store.failure = FlotsamError(.stoDb001, "write failed")
        #expect(await r.model.deleteTag(5) == nil)
        #expect(r.model.filter == .tag(5))
    }

    // MARK: Confirmed command against a changed selection (FR-004-09, -11)

    @Test func aConfirmedUngroupActsOnlyOnTheBundleThatWasConfirmed() async {
        let r = await rig(3)
        let asked = r.harness.source.rows[0].id
        let other = r.harness.source.rows[1].id
        r.model.select(id: other)  // the list reloaded or the selection moved while the question was open
        #expect(await r.model.ungroupSelected(expecting: asked) == nil)
        #expect(!r.store.calls.contains("ungroup"))
        #expect(r.harness.reported.errors.isEmpty)
        r.model.select(id: asked)
        #expect(await r.model.ungroupSelected(expecting: asked) != nil)
        #expect(r.store.calls.contains("ungroup"))
    }

    @Test func aConfirmedDeleteActsOnlyOnTheSelectionThatWasConfirmed() async {
        let r = await rig(3)
        let asked = r.harness.source.rows[0].id
        let other = r.harness.source.rows[1].id
        r.model.select(id: other)
        #expect(await r.model.deleteSelected(expecting: [asked]) == nil)
        #expect(!r.store.calls.contains { $0.hasPrefix("delete") })
        #expect(r.harness.source.rows.count == 3)
        #expect(await r.model.deleteSelected(expecting: [other]) == [other])
    }

    // MARK: Confirmation rules (FR-004-09, -11)

    private func row(_ n: Int, kind: ItemKind = .text, pinned: Bool = false, trigger: Bool = false, shortcut: Bool = false) -> ItemRow {
        let base = makeRow(n, kind: kind, pinned: pinned)
        return ItemRow(
            id: base.id, kind: kind, lastCopiedAt: base.lastCopiedAt, pasteCount: 0, primaryLine: base.primaryLine, sourceName: nil,
            tagNames: [], isPinned: pinned, hasTrigger: trigger, hasShortcut: shortcut, pixelWidth: nil, pixelHeight: nil,
            memberCount: 0, byteSize: 0)
    }

    @Test func deleteAsksOnlyForSeveralItemsOrAPinnedTriggerOrHotkeyItem() {
        #expect(!LibraryOrganizer.deleteNeedsConfirmation([row(1)]))
        #expect(LibraryOrganizer.deleteNeedsConfirmation([row(1), row(2), row(3)]))
        #expect(LibraryOrganizer.deleteNeedsConfirmation([row(1, pinned: true)]))
        #expect(LibraryOrganizer.deleteNeedsConfirmation([row(1, trigger: true)]))
        #expect(LibraryOrganizer.deleteNeedsConfirmation([row(1, shortcut: true)]))
    }

    @Test func ungroupAsksOnlyWhenSomethingIsNotCarriedOver() {
        let bundle = row(1, kind: .bundle)
        #expect(!LibraryOrganizer.ungroupNeedsConfirmation(bundle, hasNote: false))
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(bundle, hasNote: true))
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(row(1, kind: .bundle, pinned: true), hasNote: false))
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(row(1, kind: .bundle, trigger: true), hasNote: false))
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(row(1, kind: .bundle, shortcut: true), hasNote: false))
    }

    @Test func editAndUngroupNeedExactlyOneMatchingItem() {
        #expect(LibraryOrganizer.canEdit([row(1)]))
        #expect(!LibraryOrganizer.canEdit([row(1), row(2)]))
        #expect(!LibraryOrganizer.canEdit([row(1, kind: .image)]))
        #expect(LibraryOrganizer.canUngroup([row(1, kind: .bundle)]))
        #expect(!LibraryOrganizer.canUngroup([row(1)]))
        #expect(!LibraryOrganizer.canUngroup([row(1, kind: .bundle), row(2, kind: .bundle)]))
    }

    @Test func confirmationTextsComeFromTheCatalogue() {
        #expect(LibraryText.confirmDeleteTag(name: "Work", itemCount: 4) == "Remove tag 'Work' from 4 items?")
        #expect(LibraryText.confirmDelete(count: 3).contains("3 items"))
        #expect(!LibraryText.confirmDelete(count: 1).contains("1 items"))
        #expect(!LibraryText.string(LibraryText.confirmUngroup).isEmpty)
        #expect(!LibraryText.string(LibraryText.editFormattingRemoved).isEmpty)
    }
}
