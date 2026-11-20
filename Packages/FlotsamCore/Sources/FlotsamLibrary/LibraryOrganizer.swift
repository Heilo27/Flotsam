import FlotsamBase
import FlotsamStorage
import Foundation

/// The Organize commands as the Library calls them (FRD-004). `FlotsamDatabase` conforms below; tests use a fake.
/// Kind detection and keys are not here: they arrive as `ItemClassifiers` on the organizer, because Library may not
/// import Payload (ADR-0001).
public protocol LibraryOrganizeStore: Sendable {
    func togglePinned(ids: [UUID]) async -> FlotsamResult<Bool>
    func createTagAndApply(name: String, color: TagColor, to ids: [UUID]) async -> FlotsamResult<Int64>
    func toggleTag(id: Int64, on ids: [UUID]) async -> FlotsamResult<Bool>
    func renameTag(id: Int64, to name: String) async -> FlotsamResult<Bool>
    func recolorTag(id: Int64, to color: TagColor) async -> FlotsamResult<Bool>
    func deleteTag(id: Int64) async -> FlotsamResult<Int>
    func tagMembership(of ids: [UUID]) async -> FlotsamResult<[Int64: Int]>
    func setNote(_ note: String?, for id: UUID) async -> FlotsamResult<Bool>
    func note(of id: UUID) async -> FlotsamResult<String?>
    func editText(id: UUID, to text: String, classifiers: ItemClassifiers) async -> FlotsamResult<ItemKind?>
    func ungroup(bundle: UUID, classifiers: ItemClassifiers) async -> FlotsamResult<[UUID]>
    func delete(ids: [UUID]) async -> FlotsamResult<[UUID]>
    func groupIntoBundle(ids: [UUID], classifiers: ItemClassifiers) async -> FlotsamResult<UUID?>
    func renameBundle(id: UUID, to name: String) async -> FlotsamResult<Bool>
    func bundleName(of id: UUID) async -> FlotsamResult<String?>
}

/// Group and rename arrived after the other commands; a store that does not provide them refuses rather than
/// pretending (`SYS-INT-001`). `FlotsamDatabase` implements all three.
extension LibraryOrganizeStore {
    public func groupIntoBundle(ids: [UUID], classifiers: ItemClassifiers) async -> FlotsamResult<UUID?> {
        .failure(FlotsamError(.sysInt001, "This store cannot group items"))
    }

    public func renameBundle(id: UUID, to name: String) async -> FlotsamResult<Bool> {
        .failure(FlotsamError(.sysInt001, "This store cannot rename bundles"))
    }

    public func bundleName(of id: UUID) async -> FlotsamResult<String?> { .success(nil) }
}

extension FlotsamDatabase: LibraryOrganizeStore {}

/// The Library's Organize layer: which actions a selection allows, which need a confirmation, and the calls that carry
/// them out. A failure is reported once through `report` (FR-004-14: `STO-DB-001`, UI unchanged) and the call returns
/// nil or false, so the view never has to unwrap a result. Storage publishes `.itemsChanged` after each commit, which
/// the shown Library reloads on; the caller still refreshes through `LibraryViewModel.refresh(selecting:)` so its own
/// await returns with the new list and the selection it names.
@MainActor
public final class LibraryOrganizer {
    private let store: any LibraryOrganizeStore
    private let classifiers: ItemClassifiers
    private let report: @MainActor (FlotsamError) -> Void

    public init(
        store: any LibraryOrganizeStore, classifiers: ItemClassifiers,
        report: @escaping @MainActor (FlotsamError) -> Void = { _ in }
    ) {
        self.store = store
        self.classifiers = classifiers
        self.report = report
    }

    // MARK: Which actions a selection allows (FR-004-07, -09, -11)

    /// Note: exactly one item (`ItemActionRule`, the rule the context menu reads too).
    public nonisolated static func canNote(_ rows: [ItemRow]) -> Bool { ItemActionRule.note(isSingleItem: rows.count == 1) }

    /// Edit text (`ItemActionRule.edit`).
    public nonisolated static func canEdit(_ rows: [ItemRow]) -> Bool {
        guard let row = rows.first else { return false }
        return ItemActionRule.edit(kind: row.kind, isSingleItem: rows.count == 1, isSecure: row.isSecure)
    }

    /// Ungroup (`ItemActionRule.ungroup`).
    public nonisolated static func canUngroup(_ rows: [ItemRow]) -> Bool {
        guard let row = rows.first else { return false }
        return ItemActionRule.ungroup(kind: row.kind, isSingleItem: rows.count == 1)
    }

    /// Group (`ItemActionRule.group`, the rule the context menu reads too).
    public nonisolated static func canGroup(_ rows: [ItemRow]) -> Bool { ItemActionRule.group(rows) }

    /// Rename (FR-004-15): exactly one item, a bundle.
    public nonisolated static func canRenameBundle(_ rows: [ItemRow]) -> Bool { canUngroup(rows) }

    /// Group asks first when any item has something that is not carried over: a note, pin, trigger or hotkey (the
    /// Ungroup rule, FR-004-11). Notes are not on the rows, so the caller passes whether any item has one.
    public nonisolated static func groupNeedsConfirmation(_ rows: [ItemRow], anyHasNote: Bool) -> Bool {
        anyHasNote || rows.contains { $0.isPinned || $0.hasTrigger || $0.hasShortcut }
    }

    /// Delete asks first only for more than one item, or any pinned item or one with a trigger or hotkey.
    public nonisolated static func deleteNeedsConfirmation(_ rows: [ItemRow]) -> Bool {
        DeleteConfirmation.isRequired(for: rows)
    }

    /// Ungroup asks first when the bundle has something that is not carried over: a note, pin, trigger or hotkey.
    /// The note is not on the row, so the caller passes whether `note(of:)` found one.
    public nonisolated static func ungroupNeedsConfirmation(_ row: ItemRow, hasNote: Bool) -> Bool {
        hasNote || row.isPinned || row.hasTrigger || row.hasShortcut
    }

    /// Deleting a tag asks first only when the tag is on at least one item (FR-004-04).
    public nonisolated static func deleteTagNeedsConfirmation(itemCount: Int) -> Bool {
        itemCount > 0
    }

    // MARK: Pin

    /// The state applied (all pinned, or all unpinned), or nil on failure.
    public func togglePin(_ ids: [UUID]) async -> Bool? { unwrap(await store.togglePinned(ids: ids)) }

    // MARK: Tags

    public func toggleTag(_ tagId: Int64, on ids: [UUID]) async -> Bool? { unwrap(await store.toggleTag(id: tagId, on: ids)) }

    public func createTag(name: String, color: TagColor = .default, applyingTo ids: [UUID]) async -> Int64? {
        unwrap(await store.createTagAndApply(name: name, color: color, to: ids))
    }

    public func renameTag(_ tagId: Int64, to name: String) async -> Bool { unwrap(await store.renameTag(id: tagId, to: name)) != nil }

    public func recolorTag(_ tagId: Int64, to color: TagColor) async -> Bool {
        unwrap(await store.recolorTag(id: tagId, to: color)) != nil
    }

    /// The number of items the tag was on, or nil on failure. The items stay.
    public func deleteTag(_ tagId: Int64) async -> Int? { unwrap(await store.deleteTag(id: tagId)) }

    /// How many of `ids` carry each tag, for the tag menu's all, some or none marks.
    public func tagMembership(of ids: [UUID]) async -> [Int64: Int] { unwrap(await store.tagMembership(of: ids)) ?? [:] }

    // MARK: Note, edit, ungroup, delete

    public func setNote(_ note: String?, for id: UUID) async -> Bool { unwrap(await store.setNote(note, for: id)) != nil }

    public func note(of id: UUID) async -> String? { unwrap(await store.note(of: id)) ?? nil }

    /// The item's new kind, or nil when the edit was rejected or the item is gone.
    public func editText(id: UUID, to text: String) async -> ItemKind? {
        unwrap(await store.editText(id: id, to: text, classifiers: classifiers)) ?? nil
    }

    /// The new items in the bundle's member order, or nil on failure.
    public func ungroup(bundle: UUID) async -> [UUID]? { unwrap(await store.ungroup(bundle: bundle, classifiers: classifiers)) }

    /// The new bundle's id, or nil when the group was rejected or the items are gone.
    public func group(_ ids: [UUID]) async -> UUID? { unwrap(await store.groupIntoBundle(ids: ids, classifiers: classifiers)) ?? nil }

    public func renameBundle(_ id: UUID, to name: String) async -> Bool { unwrap(await store.renameBundle(id: id, to: name)) != nil }

    public func bundleName(of id: UUID) async -> String? { unwrap(await store.bundleName(of: id)) ?? nil }

    /// The ids removed, or nil on failure.
    public func delete(_ ids: [UUID]) async -> [UUID]? { unwrap(await store.delete(ids: ids)) }

    private func unwrap<T>(_ result: FlotsamResult<T>) -> T? {
        switch result {
        case .success(let value): return value
        case .failure(let error):
            report(error)
            return nil
        }
    }
}
