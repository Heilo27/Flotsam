import Carbon.HIToolbox
import FlotsamBase

/// The chords macOS itself has enabled right now, read from `CopySymbolicHotKeys()` (FR-005-02 d): Spotlight, Mission
/// Control, screenshots and the rest of System Settings > Keyboard > Keyboard Shortcuts. Read per validation, so a
/// change the user makes there is seen at once. An entry the system cannot describe is skipped, never guessed at.
struct SymbolicHotkeyProvider: SystemHotkeyProvider {
    /// Key code the system reports for a shortcut with no key (modifier-only or unassigned).
    private static let noKey = 0xFFFF

    func enabledSystemChords() -> Set<Chord> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        var chords: Set<Chord> = []
        for entry in entries {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                let code = entry[kHISymbolicHotKeyCode as String] as? Int, code != Self.noKey,
                (0...Int(UInt16.max)).contains(code),
                let flags = entry[kHISymbolicHotKeyModifiers as String] as? Int
            else { continue }
            chords.insert(Chord(keyCode: UInt16(code), modifiers: Self.modifiers(fromCarbon: flags)))
        }
        return chords
    }

    /// The inverse of `CarbonHotkeyRegistrar.carbonModifiers`.
    static func modifiers(fromCarbon flags: Int) -> ChordModifiers {
        var modifiers: ChordModifiers = []
        if flags & cmdKey != 0 { modifiers.insert(.command) }
        if flags & controlKey != 0 { modifiers.insert(.control) }
        if flags & optionKey != 0 { modifiers.insert(.option) }
        if flags & shiftKey != 0 { modifiers.insert(.shift) }
        return modifiers
    }
}
