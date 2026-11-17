import Foundation
import FlotsamBase

/// FR-005-02: the one definition of a valid global shortcut. The recorder, the item editor and the registry all call
/// this; nothing else restates the rules (Rule 9).
public enum ChordValidator {
    /// Modifier keys and fn: key codes that are never a shortcut's key (FR-005-02 b, FR-005-04).
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// Letters, digits, punctuation (US ANSI key codes), Space, Return, Tab, Escape, Delete, arrows, F1 to F20.
    static let allowedKeyCodes: Set<UInt16> = {
        var codes: Set<UInt16> = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
            31, 32, 33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 50,
        ]
        codes.formUnion([36, 48, 49, 51, 53, 123, 124, 125, 126])  // Return Tab Space Delete Escape, arrows
        codes.formUnion([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90])  // F1-F20
        return codes
    }()

    /// FR-005-02 (c). Compared on the exact modifier set, so ⌘⇧C is not reserved but ⌘C is.
    static let reserved: Set<Chord> = {
        var chords: Set<Chord> = [
            Chord(keyCode: 12, modifiers: .command),  // ⌘Q
            Chord(keyCode: 13, modifiers: .command),  // ⌘W
            Chord(keyCode: 4, modifiers: .command),  // ⌘H
            Chord(keyCode: 46, modifiers: .command),  // ⌘M
            Chord(keyCode: 48, modifiers: .command),  // ⌘Tab
            Chord(keyCode: 49, modifiers: .command),  // ⌘Space
            Chord(keyCode: 49, modifiers: .control),  // ⌃Space
            Chord(keyCode: 53, modifiers: [.command, .option]),  // ⌘⌥Esc
            Chord(keyCode: 43, modifiers: .command),  // ⌘,
        ]
        for key: UInt16 in [8, 9, 7, 6, 0] { chords.insert(Chord(keyCode: key, modifiers: .command)) }  // ⌘C V X Z A
        return chords
    }()

    /// Rules (a) to (d). `systemChords` is what macOS owns right now (`SystemHotkeyProvider`). Failure is `TRG-VAL-003`.
    public static func validate(_ chord: Chord, systemChords: Set<Chord> = []) -> FlotsamResult<Void> {
        guard chord.hasCommandOrControl else {
            return .failure(FlotsamError(.trgVal003, "Shortcut needs Command or Control"))
        }
        guard !modifierKeyCodes.contains(chord.keyCode), allowedKeyCodes.contains(chord.keyCode) else {
            return .failure(FlotsamError(.trgVal003, "Shortcut key is not a usable key"))
        }
        guard !reserved.contains(chord) else {
            return .failure(FlotsamError(.trgVal003, "Shortcut is on the reserved list"))
        }
        guard !systemChords.contains(chord) else {
            return .failure(FlotsamError(.trgVal003, "Shortcut is owned by macOS"))
        }
        return .success(())
    }
}
