import Foundation
import FlotsamBase
import FlotsamPaste

/// The key types are shared with the Shelf (FlotsamBase `KeyInput`, `KeyStroke`), so the platform layer translates an
/// `NSEvent` once; these names stay for the Library's callers.
public typealias LibraryKeyInput = KeyInput
public typealias LibraryKeyStroke = KeyStroke

public enum LibraryDirection: Sendable, Equatable { case up, down, left, right }

/// Commands whose behaviour belongs to FRD-004 (organise) and FRD-005 (triggers). The Library maps the key (FR-003-08)
/// and hands the command on.
public enum LibraryExternalCommand: Sendable, Equatable {
    case pin, tags, note, edit, delete, cycleSort, ungroup, shortcutAndTrigger

    /// The one item the shortcut-and-trigger editor opens for (FR-005-09): the editor edits a single item, so only
    /// that command with exactly one selected row resolves. Anything else, no selection or several rows, opens nothing.
    public func shortcutEditorTarget(selection ids: [UUID]) -> UUID? {
        guard self == .shortcutAndTrigger, ids.count == 1 else { return nil }
        return ids.first
    }
}

public enum LibraryCommand: Sendable, Equatable {
    case move(LibraryDirection)
    case jumpToFirst, jumpToLast
    case extend(LibraryDirection)
    case paste(PasteMode)
    /// ⌘1 to ⌘9: paste the Nth visible row.
    case pasteRow(Int)
    case togglePreview
    case escape
    case previousFilter, nextFilter
    case toggleViewMode
    case revealInFinder
    case openSettings
    case external(LibraryExternalCommand)

    /// The one rule for "this command opens a Flotsam window" (FR-003-02): Settings (⌘,) and the shortcut-and-trigger
    /// editor (⌘K, the context-menu row) open an ordinary window, and the Library hides first so the window is never
    /// covered, whatever state that window was in. The editor counts only when it will open: a selection that is not
    /// exactly one item opens nothing (FR-005-09), so the Library stays.
    public func opensFlotsamWindow(selection ids: [UUID]) -> Bool {
        switch self {
        case .openSettings: true
        case .external(let command): command.shortcutEditorTarget(selection: ids) != nil
        default: false
        }
    }
}

/// FR-003-08 as data: the one definition of what each key does. The panel, the footer hints and the tests read it here.
public enum LibraryKeyMap {
    /// What the keyboard handler needs to know about the panel to resolve a key.
    public struct Context: Sendable, Equatable {
        public var searchIsEmpty: Bool
        public var viewMode: LibraryViewMode
        /// The search field holds a non-empty text selection: ⌘C then copies that text, not the row (FR-003-08).
        public var searchHasSelection: Bool

        public init(searchIsEmpty: Bool, viewMode: LibraryViewMode, searchHasSelection: Bool = false) {
            self.searchIsEmpty = searchIsEmpty
            self.viewMode = viewMode
            self.searchHasSelection = searchHasSelection
        }
    }

    private static let table: [LibraryKeyStroke: LibraryCommand] = {
        var table: [LibraryKeyStroke: LibraryCommand] = [
            LibraryKeyStroke(.up): .move(.up),
            LibraryKeyStroke(.down): .move(.down),
            LibraryKeyStroke(.up, .command): .jumpToFirst,
            LibraryKeyStroke(.down, .command): .jumpToLast,
            LibraryKeyStroke(.up, .shift): .extend(.up),
            LibraryKeyStroke(.down, .shift): .extend(.down),
            LibraryKeyStroke(.returnKey): .paste(.paste),
            LibraryKeyStroke(.returnKey, .option): .paste(.plainText),
            LibraryKeyStroke(.returnKey, .shift): .paste(.copyOnly),
            // ⌘C is ⇧Return's copy-only path on the selected row (FR-003-08); see the selection exception in `command`.
            LibraryKeyStroke(.character("c"), .command): .paste(.copyOnly),
            LibraryKeyStroke(.character("y"), .command): .togglePreview,
            LibraryKeyStroke(.escape): .escape,
            LibraryKeyStroke(.up, .option): .previousFilter,
            LibraryKeyStroke(.down, .option): .nextFilter,
            LibraryKeyStroke(.character("g"), .command): .toggleViewMode,
            LibraryKeyStroke(.character("r"), .command): .revealInFinder,
            LibraryKeyStroke(.character(","), .command): .openSettings,
            LibraryKeyStroke(.character("p"), .command): .external(.pin),
            LibraryKeyStroke(.character("t"), .command): .external(.tags),
            LibraryKeyStroke(.character("n"), .command): .external(.note),
            LibraryKeyStroke(.character("e"), .command): .external(.edit),
            LibraryKeyStroke(.delete, .command): .external(.delete),
            LibraryKeyStroke(.character("s"), .command): .external(.cycleSort),
            LibraryKeyStroke(.character("u"), [.command, .shift]): .external(.ungroup),
            LibraryKeyStroke(.character("k"), .command): .external(.shortcutAndTrigger),
        ]
        for digit in 1...9 {
            guard let character = String(digit).first else { continue }
            table[LibraryKeyStroke(.character(character), .command)] = .pasteRow(digit)
        }
        return table
    }()

    /// The command for `stroke`, or nil when the key is not the Library's: it then goes to the search field
    /// (FR-003-08, "unhandled keys pass through").
    public static func command(for stroke: LibraryKeyStroke, in context: Context) -> LibraryCommand? {
        // Space previews only while the search field is empty; otherwise it types a space.
        if stroke.input == .space, stroke.modifiers.isEmpty { return context.searchIsEmpty ? .togglePreview : nil }
        // Left and right move through a grid; in a list they move the caret in the search field.
        if stroke.input == .left || stroke.input == .right, stroke.modifiers.isEmpty {
            guard context.viewMode == .grid else { return nil }
            return .move(stroke.input == .left ? .left : .right)
        }
        // With text selected in the search field, ⌘C is the standard text copy and goes to the field (FR-003-08).
        if stroke == LibraryKeyStroke(.character("c"), .command), context.searchHasSelection { return nil }
        return table[stroke]
    }
}
