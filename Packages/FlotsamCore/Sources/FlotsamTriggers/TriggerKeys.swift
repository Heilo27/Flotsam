import FlotsamBase
import Foundation

/// The trigger engine's constants (FRD-005 section 4 names this as their one home). The restore delay and snapshot cap
/// live with the restore itself in `ClipboardPreserver`; the trigger length limits live in `TriggerGrammar`.
public enum TriggerKeys {
    // Virtual key codes (Carbon `kVK_*`), written as numbers because Triggers may not import Carbon.
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let returnKey: UInt16 = 36
    public static let keypadEnter: UInt16 = 76
    public static let backspace: UInt16 = 51

    /// FR-005-12.
    public static let boundaryKeyCodes: Set<UInt16> = [space, tab, returnKey, keypadEnter]

    /// FR-005-11: Esc, arrows, Home, End, Page Up and Down, Forward Delete, and the function keys F1 to F20 clear the
    /// buffer. Keys that type nothing printable do too (`isPrintable`), so a key missing here still resets.
    public static let resetKeyCodes: Set<UInt16> = [
        53, 123, 124, 125, 126, 115, 119, 116, 121, 117,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// FR-005-11: the word is cleared after this long without a key event.
    public static let wordIdleTimeout: Duration = .seconds(5)
    /// FR-005-19.
    public static let watchdogInterval: Duration = .seconds(5)
    public static let disableLimit = 3
    public static let disableWindow: Duration = .seconds(60)

    /// True when `characters` is text a key typed: not empty, no control characters, and nothing from the private-use
    /// block macOS uses for arrow and function keys (U+F700 to U+F8FF).
    static func isPrintable(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            scalar.properties.generalCategory != .control && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
}
