import FlotsamBase
import FlotsamPaste

/// A key as the panel's key handler sees it, independent of AppKit: the platform layer turns an `NSEvent` into this.
public enum LibraryKeyInput: Sendable, Hashable {
    /// A printable key, lowercased (`"p"`, `"1"`, `","`).
    case character(Character)
    case returnKey, space, escape, up, down, left, right, delete
}

public struct LibraryKeyStroke: Sendable, Hashable {
    public let input: LibraryKeyInput
    public let modifiers: ChordModifiers

    public init(_ input: LibraryKeyInput, _ modifiers: ChordModifiers = []) {
        self.input = input
        self.modifiers = modifiers
    }
}

public enum LibraryDirection: Sendable, Equatable { case up, down, left, right }

/// Commands whose behaviour belongs to FRD-004 (organise) and FRD-005 (triggers). The Library maps the key (FR-003-08)
/// and hands the command on.
public enum LibraryExternalCommand: Sendable, Equatable {
    case pin, tags, note, edit, delete, cycleSort, ungroup, shortcutAndTrigger
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
}

/// FR-003-08 as data: the one definition of what each key does. The panel, the footer hints and the tests read it here.
public enum LibraryKeyMap {
    /// What the keyboard handler needs to know about the panel to resolve a key.
    public struct Context: Sendable, Equatable {
        public var searchIsEmpty: Bool
        public var viewMode: LibraryViewMode

        public init(searchIsEmpty: Bool, viewMode: LibraryViewMode) {
            self.searchIsEmpty = searchIsEmpty
            self.viewMode = viewMode
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
        return table[stroke]
    }
}
