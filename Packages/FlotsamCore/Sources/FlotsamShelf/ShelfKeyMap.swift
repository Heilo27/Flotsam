import FlotsamBase

public enum ShelfDirection: Sendable, Equatable { case previous, next }

public enum ShelfCommand: Sendable, Equatable {
    case move(ShelfDirection)
    case paste(ShelfPasteMode)
    /// Esc: with a search or type filter active it clears that first, then hides (FR-006-22).
    case hide
    /// ⌥↑ and ⌥↓ step the type pills, as they step the Library's sidebar filter (FR-006-22).
    case stepFilter(Int)
}

/// FR-006-08 as data: the one definition of what each key does in a sticky Shelf. The panel and the tests read it here.
public enum ShelfKeyMap {
    private static let table: [KeyStroke: ShelfCommand] = [
        KeyStroke(.up): .move(.previous),
        KeyStroke(.left): .move(.previous),
        KeyStroke(.down): .move(.next),
        KeyStroke(.right): .move(.next),
        KeyStroke(.returnKey): .paste(.paste),
        KeyStroke(.returnKey, .option): .paste(.plainText),
        KeyStroke(.returnKey, .shift): .paste(.copyOnly),
        KeyStroke(.character("c"), .command): .paste(.copyOnly),
        KeyStroke(.escape): .hide,
        KeyStroke(.up, .option): .stepFilter(-1),
        KeyStroke(.down, .option): .stepFilter(1),
    ]

    /// What the key map needs from the search field (FR-006-22), the Shelf's counterpart of the Library's context.
    public struct Context: Sendable, Equatable {
        /// With text in the field, Left and Right move its caret, not the card selection.
        public var searchIsEmpty: Bool
        /// With text selected in the field, ⌘C is the standard text copy and goes to the field.
        public var searchHasSelection: Bool

        public init(searchIsEmpty: Bool = true, searchHasSelection: Bool = false) {
            self.searchIsEmpty = searchIsEmpty
            self.searchHasSelection = searchHasSelection
        }
    }

    /// The command for `stroke`, or nil when the key is not the Shelf's. A transient Shelf never becomes key
    /// (FR-006-08), so it handles nothing; Space is not used.
    public static func command(for stroke: KeyStroke, isSticky: Bool, context: Context = Context()) -> ShelfCommand? {
        guard isSticky else { return nil }
        if (stroke.input == .left || stroke.input == .right), stroke.modifiers.isEmpty, !context.searchIsEmpty { return nil }
        if stroke == KeyStroke(.character("c"), .command), context.searchHasSelection { return nil }
        return table[stroke]
    }
}
