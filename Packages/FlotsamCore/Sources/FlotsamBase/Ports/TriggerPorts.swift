import Foundation

// Ports for typed triggers and item bindings (ADR-0007, ADR-0011). The adapters (CGEventTap, CGEvent posting, Text
// Input Sources, NSWorkspace) live in the app target's Platform folder; the policy lives in Triggers.

/// The single marker Flotsam stamps on every key event it posts (FR-005-13 d). The posting adapter writes it to
/// `eventSourceUserData`; the tap adapter reads it back into `KeyEvent.isFlotsamEvent`. One constant, so the writer
/// and the reader cannot disagree (Rule 9).
public enum FlotsamEventMarker {
    public static let value: Int64 = 0x464C_5453  // "FLTS"
}

public enum KeyEventKind: Sendable, Equatable {
    case keyDown
    case keyUp
    /// Left, right or other mouse button down: only ever used to reset the word (FR-005-11).
    case mouseDown
}

/// Modifier state of a key event, as the tap sees it. Caps Lock is separate from `ChordModifiers` because a chord can
/// never include it but typing with it on must still count as typing (FR-005-11).
public struct KeyEventFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = KeyEventFlags(rawValue: 1 << 0)
    public static let control = KeyEventFlags(rawValue: 1 << 1)
    public static let option = KeyEventFlags(rawValue: 1 << 2)
    public static let shift = KeyEventFlags(rawValue: 1 << 3)
    public static let capsLock = KeyEventFlags(rawValue: 1 << 4)

    /// Anything other than Shift or Caps Lock: such a key is a command, not typing.
    public var hasCommandModifier: Bool { !isDisjoint(with: [.command, .control, .option]) }
}

/// One event as the tap adapter hands it to policy. A plain value: no CGEvent crosses the port.
public struct KeyEvent: Sendable, Equatable {
    public let kind: KeyEventKind
    public let keyCode: UInt16
    public let flags: KeyEventFlags
    /// What the key types in the current layout (`CGEventKeyboardGetUnicodeString`); empty for non-text keys.
    public let characters: String
    public let isAutoRepeat: Bool
    /// True when the event carries `FlotsamEventMarker.value`.
    public let isFlotsamEvent: Bool

    public init(
        kind: KeyEventKind, keyCode: UInt16 = 0, flags: KeyEventFlags = [], characters: String = "",
        isAutoRepeat: Bool = false, isFlotsamEvent: Bool = false
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.characters = characters
        self.isAutoRepeat = isAutoRepeat
        self.isFlotsamEvent = isFlotsamEvent
    }
}

/// What the tap does with the event it just handed over.
public enum KeyDecision: Sendable, Equatable {
    case pass
    /// Swallow the event (the application never sees it).
    case consume
}

/// Why macOS turned the tap off (FR-005-19).
public enum TapDisableReason: Sendable, Equatable {
    case timeout
    case userInput
}

/// The keyboard tap, as policy sees it (ADR-0007). The adapter owns the CGEventTap and its thread; `handler` runs on
/// that thread, synchronously, and must be fast (FR-005-21). `onDisabled` runs on the same thread.
public protocol KeyEventSource: AnyObject, Sendable {
    /// Installs the tap. `TRG-OS-003`-class failure to install is returned for the caller to report.
    func start(
        handler: @escaping @Sendable (KeyEvent) -> KeyDecision,
        onDisabled: @escaping @Sendable (TapDisableReason) -> Void
    ) -> FlotsamResult<Void>
    /// Removes the tap and stops its thread. Idempotent.
    func stop()
    /// False when the tap is installed but macOS has disabled it, or when none is installed.
    var isHealthy: Bool { get }
    /// Re-enables a disabled tap; false when it could not be.
    func reenable() -> Bool
}

/// The three things the match decision asks the system (FR-005-13). Called only when a word has actually matched a
/// trigger, so none of them is on the per-keystroke path.
public protocol KeyboardEnvironment: Sendable {
    func isSecureEventInputEnabled() -> Bool
    /// True when the current input source is an input method (Japanese, Chinese, Korean composition), not a layout.
    func isInputMethodActive() -> Bool
    /// The frontmost application, from a cache the adapter keeps current; safe to read off the main thread.
    func frontmostApp() -> FrontmostApp?
}

/// Posts the synthetic keys a trigger expansion needs, on top of ⌘V (FR-005-14, FR-005-15). Every event carries
/// `FlotsamEventMarker.value`. `KeyEventPoster.postPaste()` carries it too.
@MainActor
public protocol TriggerKeyPoster: KeyEventPoster {
    /// Key down then key up, `count` times, back to back (FR-005-14 step 5 uses key code 51, FR-005-15 re-posts the
    /// boundary key). Every event is created before any is posted, so false means none was posted.
    func postKeyPress(keyCode: UInt16, count: Int) -> Bool
    /// Types `text` as one Unicode string event (FR-005-15 re-types the trigger).
    func postText(_ text: String) -> Bool
}

/// The chords macOS itself owns right now: enabled symbolic hotkeys from `CopySymbolicHotKeys()` (FR-005-02 d).
public protocol SystemHotkeyProvider: Sendable {
    func enabledSystemChords() -> Set<Chord>
}

/// Hotkeys and triggers stored on items, read once to build the registry and the trigger snapshot (FR-005-01,
/// FR-005-12). Lives in Base so Shortcuts and Triggers read the same shape without importing Storage's internals.
public struct ItemBindings: Sendable, Equatable {
    public var hotkeys: [UUID: Chord]
    public var triggers: [UUID: String]

    public init(hotkeys: [UUID: Chord] = [:], triggers: [UUID: String] = [:]) {
        self.hotkeys = hotkeys
        self.triggers = triggers
    }
}

public protocol ItemBindingSource: Sendable {
    func itemBindings() async -> FlotsamResult<ItemBindings>
}
