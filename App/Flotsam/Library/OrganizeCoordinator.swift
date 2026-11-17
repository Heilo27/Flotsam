import FlotsamBase
import FlotsamLibrary
import FlotsamStorage
import Foundation
import Observation

/// A yes/no question the Library asks before a destructive Organize command (FR-004-04, -09, -11).
struct OrganizeConfirmation {
    let message: String
    let buttonTitle: String
    let action: @MainActor () async -> Void
}

/// What the Organize layer is showing over the Library panel. They are in-panel overlays rather than popovers, sheets
/// or alerts: the panel hides when it loses key focus, and a separate window would take it.
enum OrganizeOverlay {
    case confirm(OrganizeConfirmation)
    case tags
    case note(UUID)
    case edit(UUID, kind: ItemKind)
    case renameTag(Int64)
}

/// Drives the Organize UI (FRD-004): turns the Library's `.external` commands into confirmations and editors, runs the
/// commands through the view model, and shows a rejected input (ORG-VAL, ORG-LIM) inline instead of as a HUD. Rules and
/// storage are not here; they live in `LibraryOrganizer` and the store.
@MainActor
@Observable
final class OrganizeCoordinator {
    private(set) var overlay: OrganizeOverlay?
    /// The inline message for the last rejected input in the open overlay (FR-004-02, -06, -07).
    private(set) var validation: String?
    var tagQuery = ""
    /// The text the note, edit and rename overlays are editing.
    var draft = ""
    /// How many of the selected items carry each tag, for the tag list's all, some or none marks.
    private(set) var membership: [Int64: Int] = [:]
    private(set) var selectionCount = 0

    @ObservationIgnored weak var model: LibraryViewModel?
    @ObservationIgnored var organizer: LibraryOrganizer?
    @ObservationIgnored private let report: @MainActor (FlotsamError, ErrorOrigin) -> Void
    @ObservationIgnored private let loadContent: @MainActor (UUID) async -> FlotsamResult<ItemContent>
    /// ⌘K belongs to FRD-005; this stays inert until that feature fills the closure.
    @ObservationIgnored private let shortcutAndTrigger: @MainActor ([UUID]) -> Void

    init(
        report: @escaping @MainActor (FlotsamError, ErrorOrigin) -> Void,
        loadContent: @escaping @MainActor (UUID) async -> FlotsamResult<ItemContent>,
        shortcutAndTrigger: @escaping @MainActor ([UUID]) -> Void
    ) {
        self.report = report
        self.loadContent = loadContent
        self.shortcutAndTrigger = shortcutAndTrigger
    }

    var isOverlayOpen: Bool { overlay != nil }

    /// The inline codes: a rejected tag name, note or edit stays in the open overlay. Everything else is a HUD.
    private static let inlineCodes: Set<ErrorCode> = [.orgVal001, .orgVal002, .orgVal003, .orgLim001, .orgLim002, .orgLim003]

    /// The organizer's `report` closure (FR-004-14): a rejected input shows inline and is still logged and recorded
    /// (FR-000-08 d), any other failure is reported as a HUD.
    func surface(_ error: FlotsamError) {
        if overlay != nil, Self.inlineCodes.contains(error.code) {
            validation = FlotsamStrings.message(for: error)
            report(error, .inline)
        } else {
            report(error, .userInitiated)
        }
    }

    // MARK: Commands from the key map and the context menus

    func perform(_ command: LibraryExternalCommand, ids: [UUID]) {
        guard overlay == nil, let model else { return }
        switch command {
        case .pin: Task { _ = await model.togglePinSelected() }
        case .tags: openTags(model)
        case .note: openNote(model)
        case .edit: openEdit(model)
        case .delete: requestDelete(model)
        case .ungroup: requestUngroup(model)
        case .shortcutAndTrigger: shortcutAndTrigger(ids)
        case .cycleSort: break  // the view model owns sort cycling
        }
    }

    private func openTags(_ model: LibraryViewModel) {
        guard !model.selection.isEmpty else { return }
        Task {
            let counts = await model.tagMembershipOfSelection()
            membership = counts
            selectionCount = model.selection.count
            tagQuery = ""
            validation = nil
            overlay = .tags
        }
    }

    private func openNote(_ model: LibraryViewModel) {
        guard let id = model.selectedRow?.id, let organizer else { return }
        Task {
            draft = await organizer.note(of: id) ?? ""
            validation = nil
            overlay = .note(id)
        }
    }

    private func openEdit(_ model: LibraryViewModel) {
        let rows = model.selectedRows
        guard LibraryOrganizer.canEdit(rows), let row = rows.first else { return }
        Task {
            switch await loadContent(row.id) {
            case .success(let content):
                draft = content.plainText ?? ""
                validation = nil
                overlay = .edit(row.id, kind: row.kind)
            case .failure(let error): report(error, .userInitiated)
            }
        }
    }

    private func requestDelete(_ model: LibraryViewModel) {
        let rows = model.selectedRows
        guard !rows.isEmpty else { return }
        if LibraryOrganizer.deleteNeedsConfirmation(rows) {
            confirm(message: LibraryText.confirmDelete(count: rows.count), button: LibraryText.buttonDelete) {
                _ = await model.deleteSelected()
            }
        } else {
            Task { _ = await model.deleteSelected() }
        }
    }

    /// The bundle's note is not on the row, so it is read before deciding whether to ask (FR-004-11).
    private func requestUngroup(_ model: LibraryViewModel) {
        let rows = model.selectedRows
        guard LibraryOrganizer.canUngroup(rows), let row = rows.first, let organizer else { return }
        Task {
            let hasNote = await organizer.note(of: row.id) != nil
            if LibraryOrganizer.ungroupNeedsConfirmation(row, hasNote: hasNote) {
                confirm(message: LibraryText.string(LibraryText.confirmUngroup), button: LibraryText.buttonUngroup) {
                    _ = await model.ungroupSelected()
                }
            } else {
                _ = await model.ungroupSelected()
            }
        }
    }

    private func confirm(message: String, button: String, _ action: @escaping @MainActor () async -> Void) {
        validation = nil
        overlay = .confirm(OrganizeConfirmation(message: message, buttonTitle: button, action: action))
    }

    // MARK: Sidebar tag management (FR-004-04)

    func renameTag(id: Int64, currentName: String) {
        guard overlay == nil else { return }
        draft = currentName
        validation = nil
        overlay = .renameTag(id)
    }

    func recolorTag(id: Int64, to color: TagColor) {
        guard let model else { return }
        Task { _ = await model.recolorTag(id, to: color) }
    }

    /// Asks first only when the tag is on at least one item.
    func deleteTag(id: Int64, name: String, itemCount: Int) {
        guard overlay == nil, let model else { return }
        if itemCount > 0 {
            confirm(message: LibraryText.confirmDeleteTag(name: name, itemCount: itemCount), button: LibraryText.buttonRemove) {
                _ = await model.deleteTag(id)
            }
        } else {
            Task { _ = await model.deleteTag(id) }
        }
    }

    // MARK: Tag picker (FR-004-02, -03)

    /// Tags matching the field, ignoring case and diacritics; all of them when the field is empty.
    func matchingTags(in tags: [SidebarCounts.TagCount]) -> [SidebarCounts.TagCount] {
        let query = trimmedQuery
        guard !query.isEmpty else { return tags }
        return tags.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// "Create tag" shows when the field has text and no tag has exactly that name.
    func canCreate(among tags: [SidebarCounts.TagCount]) -> Bool {
        let query = trimmedQuery
        guard !query.isEmpty else { return false }
        return !tags.contains { $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    var trimmedQuery: String { tagQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    func toggleTag(_ id: Int64) {
        guard let model else { return }
        validation = nil
        Task {
            _ = await model.toggleTagOnSelection(id)
            membership = await model.tagMembershipOfSelection()
        }
    }

    func createTag() {
        guard let model, !trimmedQuery.isEmpty else { return }
        let name = trimmedQuery
        validation = nil
        Task {
            if await model.createTagOnSelection(name: name) != nil { tagQuery = "" }
            membership = await model.tagMembershipOfSelection()
        }
    }

    /// Return in the field toggles the first match, or creates the tag when nothing matches (FR-004-03).
    func submitTagField() {
        guard let model else { return }
        let tags = model.sidebar?.tags ?? []
        if let first = matchingTags(in: tags).first { toggleTag(first.id) } else { createTag() }
    }

    // MARK: Note, edit and rename

    /// ⌘Return, or the Save button, in the note, edit and rename overlays; Return in a confirmation.
    func primaryAction() {
        guard let overlay, let model else { return }
        switch overlay {
        case .confirm(let confirmation):
            close()
            Task { await confirmation.action() }
        case .tags: break
        case .note(let id):
            validation = nil
            // Only a zero-length note removes it; spaces and newlines are stored as typed (FR-004-06).
            let note: String? = draft.isEmpty ? nil : draft
            Task { if await model.saveNote(note, for: id) { close() } }
        case .edit:
            validation = nil
            Task { if await model.saveEdit(text: draft) != nil { close() } }
        case .renameTag(let id):
            validation = nil
            Task { if await model.renameTag(id, to: draft) { close() } }
        }
    }

    func close() {
        overlay = nil
        validation = nil
        draft = ""
        tagQuery = ""
    }

    /// Keys while an overlay is open: Esc cancels, ⌘Return saves, Return confirms a question. Everything else belongs
    /// to the overlay's text field, never to the Library's key map. True when the key was consumed.
    func handle(_ stroke: LibraryKeyStroke) -> Bool {
        guard let overlay else { return false }
        if stroke.input == .escape, stroke.modifiers.isEmpty { close(); return true }
        guard stroke.input == .returnKey else { return false }
        switch overlay {
        case .confirm where stroke.modifiers.isEmpty, .note where stroke.modifiers == .command,
             .edit where stroke.modifiers == .command, .renameTag where stroke.modifiers.isEmpty:
            primaryAction()
            return true
        default: return false
        }
    }
}
