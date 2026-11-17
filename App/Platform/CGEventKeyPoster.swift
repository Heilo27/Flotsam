import CoreGraphics
import FlotsamBase

/// Posts ⌘V: key code 9 with the Command flag, key down then key up, to the session event tap (FR-003-15 step 6).
@MainActor
struct CGEventKeyPoster: KeyEventPoster {
    private static let vKeyCode: CGKeyCode = 9

    func postPaste() -> Bool {
        // A private source keeps the user's held modifiers (for example the ⌥ of ⌥Return) out of the posted events.
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
