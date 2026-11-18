import Foundation
import FlotsamBase

/// FR-005-02: the one definition of a valid global shortcut. The recorder, the item editor and the registry all call
/// this; nothing else restates the rules (Rule 9).
public enum ChordValidator {
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
        guard chord.hasUsableKey else {
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
