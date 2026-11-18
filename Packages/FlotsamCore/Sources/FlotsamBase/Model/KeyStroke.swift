/// A key as a panel's key handler sees it, independent of AppKit: the platform layer turns an `NSEvent` into this.
/// Shared by the Library and the Shelf key maps (one translation, one set of cases).
public enum KeyInput: Sendable, Hashable {
    /// A printable key, lowercased (`"p"`, `"1"`, `","`).
    case character(Character)
    case returnKey, space, escape, up, down, left, right, delete
}

public struct KeyStroke: Sendable, Hashable {
    public let input: KeyInput
    public let modifiers: ChordModifiers

    public init(_ input: KeyInput, _ modifiers: ChordModifiers = []) {
        self.input = input
        self.modifiers = modifiers
    }
}
