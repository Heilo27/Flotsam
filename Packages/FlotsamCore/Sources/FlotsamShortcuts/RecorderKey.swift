import FlotsamBase

/// What one key press means to a shortcut recorder (FR-005-04). The one home of the Esc and Delete rules, so the
/// Settings recorder and the item editor's recorder (FR-005-09) cannot differ.
public enum RecorderKey: Sendable, Equatable {
    /// Esc alone: stop recording and change nothing.
    case cancel
    /// Delete or Backspace alone: clear the binding (the caller refuses where clearing is not allowed).
    case clear
    /// Anything else: a chord to validate. A press of a modifier key alone never reaches here (it is not a key-down);
    /// validation (FR-005-02) rejects a chord without ⌘ or ⌃.
    case chord(Chord)

    public static let escapeKeyCode: UInt16 = 53
    public static let deleteKeyCode: UInt16 = 51
    public static let forwardDeleteKeyCode: UInt16 = 117

    public static func interpret(keyCode: UInt16, modifiers: ChordModifiers) -> RecorderKey {
        if modifiers.isEmpty {
            if keyCode == escapeKeyCode { return .cancel }
            if keyCode == deleteKeyCode || keyCode == forwardDeleteKeyCode { return .clear }
        }
        return .chord(Chord(keyCode: keyCode, modifiers: modifiers))
    }
}
