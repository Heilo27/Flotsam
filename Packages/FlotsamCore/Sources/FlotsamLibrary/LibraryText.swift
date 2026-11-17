import FlotsamBase
import Foundation

/// The Library's user-facing text. Every string is a catalogue key (FR-000-05); the views and the presentation models
/// both read it here, so a key is spelled once.
public enum LibraryText {
    public static func string(_ key: String) -> String {
        FlotsamStrings.text(forKey: key) ?? ""
    }

    /// Fills a catalogue template. Only `%lld` and `%@` appear in templates (the catalogue lint), and each call site
    /// passes exactly the matching argument types.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }

    public static let panelTitle = "ui.library.panelTitle"
    public static let searchPlaceholder = "ui.library.searchPlaceholder"
    public static let emptyTitle = "ui.library.emptyTitle"
    public static let emptyBody = "ui.library.emptyBody"
    public static let noResultsBody = "ui.library.noResultsBody"
    public static let clearSearchButton = "ui.btn.clearSearch"
    public static let retryButton = "ui.btn.retry"
    public static let errorTitle = "ui.library.errorTitle"
    public static let previewShowMore = "ui.library.previewShowMore"
    public static let previewUnavailable = "ui.library.previewUnavailable"
    public static let menuPaste = "ui.library.menuPaste"
    public static let menuPastePlain = "ui.library.menuPastePlain"
    public static let menuCopy = "ui.library.menuCopy"
    public static let menuPreview = "ui.library.menuPreview"
    public static let menuReveal = "ui.library.menuReveal"
    public static let sectionTypes = "ui.library.sectionTypes"
    public static let sectionTags = "ui.library.sectionTags"
    public static let sectionApps = "ui.library.sectionApps"

    public static func noResultsTitle(query: String) -> String { format("ui.library.noResultsTitle", query) }

    public static func itemCount(_ count: Int) -> String {
        count == 1 ? string("ui.library.footerOneItem") : format("ui.library.footerItems", count)
    }

    public static func selectedCount(_ count: Int) -> String { format("ui.library.footerSelected", count) }

    /// "Files", "Rich Text": the plural type names of the sidebar (distinct from `KindLabel`, which is the singular used
    /// in rows and in search).
    public static func typeTitle(_ kind: ItemKind) -> String {
        let raw = kind.rawValue
        return string("ui.library.type" + raw.prefix(1).uppercased() + raw.dropFirst())
    }
}
