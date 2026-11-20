import FlotsamBase
import Foundation

/// The Library's user-facing text. Every string is a catalogue key (FR-000-05); the views and the presentation models
/// both read it here, so a key is spelled once.
public enum LibraryText {
    public static func string(_ key: String) -> String {
        FlotsamStrings.text(forKey: key) ?? ""
    }

    /// Fills a catalogue template, resolving a plural slot by its count (FR-000-05). Only `%lld`, `%@` and plural slots
    /// appear in templates (the catalogue lint), and each call site passes exactly the matching argument types.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        FlotsamStrings.formatted(forKey: key, arguments) ?? ""
    }

    public static let panelTitle = "ui.library.panelTitle"
    public static let searchPlaceholder = "ui.library.searchPlaceholder"
    public static let emptyTitle = "ui.library.emptyTitle"
    public static let emptyBody = "ui.library.emptyBody"
    public static let noResultsBody = "ui.library.noResultsBody"
    public static let clearSearchButton = "ui.btn.clearSearch"
    public static let retryButton = "ui.btn.retry"
    public static let errorTitle = "ui.library.errorTitle"
    public static let emptyTagBody = "ui.library.emptyTagBody"
    public static let previewShowMore = "ui.library.previewShowMore"
    public static let previewUnavailable = "ui.library.previewUnavailable"
    public static let menuPaste = "ui.library.menuPaste"
    public static let menuPastePlain = "ui.library.menuPastePlain"
    public static let menuCopy = "ui.library.menuCopy"
    public static let menuPreview = "ui.library.menuPreview"
    public static let menuReveal = "ui.library.menuReveal"
    public static let menuShortcutAndTrigger = "ui.library.menuShortcutAndTrigger"
    public static let sectionTypes = "ui.library.sectionTypes"
    public static let sectionTags = "ui.library.sectionTags"
    public static let sectionApps = "ui.library.sectionApps"
    /// The Types section header's tooltip and VoiceOver hint: what a click does now (FR-003-12).
    public static let typesHide = "ui.library.typesHide"
    public static let typesShow = "ui.library.typesShow"

    public static func noResultsTitle(query: String) -> String { format("ui.library.noResultsTitle", query) }

    /// "Nothing tagged “Work” yet": a tag chosen in the sidebar that has no items (FR-003-50).
    public static func emptyTagTitle(name: String) -> String { format("ui.library.emptyTagTitle", name) }

    public static func itemCount(_ count: Int) -> String {
        format("ui.library.footerItems", count)
    }

    /// "and 3 more": the file members past the preview's limit.
    public static func previewMore(_ count: Int) -> String { format("ui.library.previewMore", count) }

    // MARK: Organize (FRD-004)

    public static func sortName(_ sort: LibrarySort) -> String { string("ui.organize.sort" + sort.rawValue.prefix(1).uppercased() + sort.rawValue.dropFirst()) }

    public static func confirmDeleteTag(name: String, itemCount: Int) -> String {
        format("ui.organize.confirmDeleteTag", name, itemCount)
    }

    public static func confirmDelete(count: Int) -> String {
        DeleteConfirmation.message(count: count)
    }

    public static let confirmUngroup = "ui.organize.confirmUngroup"
    public static let confirmGroup = "ui.organize.confirmGroup"

    public static let tagFieldPlaceholder = "ui.organize.tagFieldPlaceholder"
    public static let tagsTitle = "ui.organize.tagsTitle"
    public static let noteTitle = "ui.organize.noteTitle"
    public static let editTitle = "ui.organize.editTitle"
    public static let menuPin = "ui.organize.menuPin"
    public static let menuUnpin = "ui.organize.menuUnpin"
    public static let menuTags = "ui.organize.menuTags"
    public static let menuNote = "ui.organize.menuNote"
    public static let menuEdit = "ui.organize.menuEdit"
    public static let menuUngroup = "ui.organize.menuUngroup"
    public static let menuGroup = "ui.organize.menuGroup"
    public static let menuDelete = "ui.organize.menuDelete"
    public static let menuRename = "ui.organize.menuRename"
    public static let menuColor = "ui.organize.menuColor"
    public static let buttonSave = "ui.organize.buttonSave"
    public static let buttonCancel = "ui.organize.buttonCancel"
    public static let buttonDelete = "ui.organize.buttonDelete"
    public static let buttonRemove = "ui.organize.buttonRemove"
    public static let buttonUngroup = "ui.organize.buttonUngroup"
    public static let buttonGroup = "ui.organize.buttonGroup"

    public static func colorName(_ color: TagColor) -> String {
        string("ui.organize.color" + color.rawValue.prefix(1).uppercased() + color.rawValue.dropFirst())
    }

    public static func createTag(name: String) -> String { format("ui.organize.tagCreate", name) }

    public static func noteCounter(_ count: Int) -> String { format("ui.organize.noteCounter", count) }
    public static let editFormattingRemoved = "ui.organize.editFormattingRemoved"

    public static func selectedCount(_ count: Int) -> String { format("ui.library.footerSelected", count) }

    /// "Files", "Rich Text": the plural type names of the sidebar (distinct from `KindLabel`, which is the singular used
    /// in rows and in search).
    public static func typeTitle(_ kind: ItemKind) -> String {
        let raw = kind.rawValue
        return string("ui.library.type" + raw.prefix(1).uppercased() + raw.dropFirst())
    }
}
