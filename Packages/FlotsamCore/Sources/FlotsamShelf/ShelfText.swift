import FlotsamBase
import Foundation

/// The Shelf's user-facing text (FR-006-06 to -09). Every string is a catalogue key (FR-000-05), spelled once here.
/// Menu titles that match the Library's (Paste, Paste as Plain Text, Copy) and the "Pinned" label reuse the Library's
/// catalogue keys by name, so one wording serves both surfaces; the Shelf module cannot import FlotsamLibrary, so the
/// key strings are repeated here, not the Library's constants.
public enum ShelfText {
    public static func string(_ key: String) -> String {
        FlotsamStrings.text(forKey: key) ?? ""
    }

    public static let empty = "ui.shelf.empty"
    public static let dropZone = "ui.shelf.drop"
    public static let shareZone = "ui.shelf.share"
    public static let close = "ui.shelf.close"
    /// The collapsed edge bar's accessibility label (FR-006-37).
    public static let edgeBar = "ui.shelf.edgeBar"
    public static let sectionPinned = "ui.library.pinned"
    public static let sectionRecent = "ui.shelf.sectionRecent"
    public static let menuPaste = "ui.library.menuPaste"
    public static let menuPastePlain = "ui.library.menuPastePlain"
    public static let menuCopy = "ui.library.menuCopy"
    public static let menuPin = "ui.shelf.menuPin"
    public static let menuUnpin = "ui.shelf.menuUnpin"
    public static let menuDelete = "ui.shelf.menuDelete"
    public static let missing = "ui.shelf.missing"
    /// The badge of a secure card whose key is gone. The Library's key, by name: one string, one translation (the
    /// reason `ui.shelf.secureUnavailable` was removed).
    public static let secureUnavailable = "ui.library.secureUnavailable"
    /// The delete confirmation reuses FRD-004's catalogue keys (`ui.organize.confirmDelete*`, via
    /// `DeleteConfirmation.message(count:)`); the button's key is named here for the confirmation dialog.
    /// The search header (FR-006-22) reuses the Library's keys by name, so the Shelf's search speaks the Library's words.
    public static let searchPlaceholder = "ui.library.searchPlaceholder"
    public static let filterAll = "ui.library.sidebarAll"
    public static let noResultsBody = "ui.library.noResultsBody"

    /// "No matches for “query”", as the Library words it.
    public static func noResultsTitle(query: String) -> String {
        FlotsamStrings.formatted(forKey: "ui.library.noResultsTitle", [query]) ?? ""
    }

    /// The plural type name on a pill, the Library sidebar's own ("Files", "Rich Text"). The key derivation repeats
    /// `LibraryText.typeTitle` (the Shelf cannot import FlotsamLibrary); change both together.
    public static func typeTitle(_ kind: ItemKind) -> String {
        let raw = kind.rawValue
        return string("ui.library.type" + raw.prefix(1).uppercased() + raw.dropFirst())
    }

    public static let buttonDelete = "ui.organize.buttonDelete"
    public static let buttonCancel = "ui.organize.buttonCancel"
}
