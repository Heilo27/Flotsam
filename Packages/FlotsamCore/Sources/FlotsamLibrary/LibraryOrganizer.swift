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
}

extension FlotsamDatabase: LibraryOrganizeStore {}

/// The Library's Organize layer: which actions a selection allows, which need a confirmation, and the calls that carry
/// them out. A failure is reported once through `report` (FR-004-14: `STO-DB-001`, UI unchanged) and the call returns
/// nil or false, so the view never has to unwrap a result. Storage publishes `.itemsChanged` after each commit; the
/// caller refreshes the list through `LibraryViewModel.refresh(selecting:)`.
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

    /// Edit text: exactly one item, of a text-like kind.
    public nonisolated static func canEdit(_ rows: [ItemRow]) -> Bool {
        rows.count == 1 && rows[0].kind.isTextEditable
    }

    /// Ungroup: exactly one item, a bundle.
    public nonisolated static func canUngroup(_ rows: [ItemRow]) -> Bool {
        rows.count == 1 && rows[0].kind == .bundle
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
