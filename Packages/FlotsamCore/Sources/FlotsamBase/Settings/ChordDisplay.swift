import Foundation

/// Text for a chord, for menu rows and labels. The key table is the US ANSI layout; a layout-aware table belongs with
/// the recorder (FRD-005), which should replace this when it lands.
extension Chord {
    private static let keys: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
        14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j",
        39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 49: " ", 50: "`",
    ]

    /// The character a menu item uses as its key equivalent; nil for a key the table does not know.
    public var keyEquivalent: String? { Self.keys[keyCode] }

    /// One string per keycap, in the system order (control, option, shift, command), then the key: ["⌃", "⌘", "V"].
    /// The key is one cap even when its name is longer ("Space"). `displayString` is these joined, so the recorder's
    /// keycaps and every other chord text come from this one place.
    public var keycaps: [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("\u{2303}") }
        if modifiers.contains(.option) { caps.append("\u{2325}") }
        if modifiers.contains(.shift) { caps.append("\u{21E7}") }
        if modifiers.contains(.command) { caps.append("\u{2318}") }
        caps.append(keyEquivalent.map { $0 == " " ? "Space" : $0.uppercased() } ?? "#\(keyCode)")
        return caps
    }

    /// Modifier glyphs in the system order (control, option, shift, command), then the key: "⌃⌘V".
    public var displayString: String { keycaps.joined() }
}
