import AppKit
import FlotsamBase
import FlotsamLibrary

/// Turns an `NSEvent` into the AppKit-free `LibraryKeyStroke` the key map resolves (FR-003-08). The key table itself
/// lives in `LibraryKeyMap`; this only reads the hardware event.
enum LibraryKeyTranslator {
    private static let specialKeys: [UInt16: LibraryKeyInput] = [
        36: .returnKey, 76: .returnKey, 49: .space, 53: .escape,
        126: .up, 125: .down, 123: .left, 124: .right, 51: .delete, 117: .delete,
    ]

    static func stroke(for event: NSEvent) -> LibraryKeyStroke? {
        let modifiers = chordModifiers(event.modifierFlags)
        if let special = specialKeys[event.keyCode] { return LibraryKeyStroke(special, modifiers) }
        guard let first = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
        return LibraryKeyStroke(.character(first), modifiers)
    }

    private static func chordModifiers(_ flags: NSEvent.ModifierFlags) -> ChordModifiers {
        var modifiers: ChordModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
