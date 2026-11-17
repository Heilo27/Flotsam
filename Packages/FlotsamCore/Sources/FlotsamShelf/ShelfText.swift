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
    public static let close = "ui.shelf.close"
    public static let sectionPinned = "ui.library.pinned"
    public static let sectionRecent = "ui.shelf.sectionRecent"
    public static let menuPaste = "ui.library.menuPaste"
    public static let menuPastePlain = "ui.library.menuPastePlain"
    public static let menuCopy = "ui.library.menuCopy"
    public static let menuPin = "ui.shelf.menuPin"
    public static let menuUnpin = "ui.shelf.menuUnpin"
    public static let menuDelete = "ui.shelf.menuDelete"
    public static let missing = "ui.shelf.missing"
}
