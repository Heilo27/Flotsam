import CoreGraphics
import FlotsamBase

/// Posts the synthetic keys Flotsam needs: ⌘V for paste-back (FR-003-15 step 6) and, for typed triggers, backspaces,
/// re-posted boundary keys and re-typed text (FR-005-14, FR-005-15). Every event is stamped with
/// `FlotsamEventMarker.value` so the typed-trigger tap ignores it (FR-005-13 d); `makeKeyEvents` is the one place that
/// stamps, so no posted event can miss the marker.
@MainActor
struct CGEventKeyPoster: TriggerKeyPoster {
    private static let vKeyCode: CGKeyCode = 9
    /// `CGEventKeyboardSetUnicodeString` is only reliable up to about 20 UTF-16 units per event.
    private static let maxUnitsPerTextEvent = 20

    func postPaste() -> Bool {
        guard let events = Self.makeKeyEvents(keyCode: Self.vKeyCode, flags: .maskCommand) else { return false }
        Self.post(events)
        return true
    }

    func postKeyPress(keyCode: UInt16, count: Int) -> Bool {
        guard count >= 0 else { return false }
        // Every event is created before any is posted, so a creation failure posts nothing.
        var pending: [CGEvent] = []
        for _ in 0..<count {
            guard let events = Self.makeKeyEvents(keyCode: keyCode, flags: []) else { return false }
            pending.append(contentsOf: events)
        }
        Self.post(pending)
        return true
    }

    func postText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var pending: [CGEvent] = []
        for chunk in Self.chunks(of: text) {
            guard let events = Self.makeKeyEvents(keyCode: 0, flags: []) else { return false }
            let units = Array(chunk.utf16)
            for event in events { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
            pending.append(contentsOf: events)
        }
        Self.post(pending)
        return true
    }

    /// Key down then key up for one key, from a private source so the user's held modifiers (for example the ⌥ of
    /// ⌥Return) stay out of the posted events, both stamped with the Flotsam marker.
    private static func makeKeyEvents(keyCode: CGKeyCode, flags: CGEventFlags) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .privateState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return nil }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: FlotsamEventMarker.value)
        }
        return [down, up]
    }

    private static func post(_ events: [CGEvent]) {
        for event in events { event.post(tap: .cgSessionEventTap) }
    }

    /// Splits at character boundaries so no event carries half a surrogate pair or a split grapheme.
    private static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var units = 0
        for character in text {
            let length = String(character).utf16.count
            if units + length > maxUnitsPerTextEvent, !current.isEmpty {
                result.append(current)
                current = ""
                units = 0
            }
            current.append(character)
            units += length
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
