import FlotsamBase

public enum ShelfDirection: Sendable, Equatable { case previous, next }

public enum ShelfCommand: Sendable, Equatable {
    case move(ShelfDirection)
    case paste(ShelfPasteMode)
    case hide
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
    ]

    /// The command for `stroke`, or nil when the key is not the Shelf's. A transient Shelf never becomes key
    /// (FR-006-08), so it handles nothing; Space is not used.
    public static func command(for stroke: KeyStroke, isSticky: Bool) -> ShelfCommand? {
        guard isSticky else { return nil }
        return table[stroke]
    }
}
