import Foundation

// Global hotkey ports (ADR-0006). The Carbon adapter lives in the app target's Platform folder; the chord model and
// validation (FR-005-02) live in Shortcuts. FRD-005 may extend these; it must not declare a second registrar.

/// Opaque handle for one registered hotkey, used to unregister it.
public struct HotkeyRegistration: Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

/// Registers system-wide hotkeys that need no Accessibility permission (FR-005-03).
@MainActor
public protocol HotkeyRegistrar {
    /// Registers `chord`; `handler` runs on the main actor at key-down. `TRG-OS-001` when the OS refuses.
    func register(_ chord: Chord, handler: @escaping @MainActor () -> Void) -> FlotsamResult<HotkeyRegistration>
    func unregister(_ registration: HotkeyRegistration)
    func unregisterAll()
}

/// Where the Library hotkey comes from: the `shortcuts.openLibrary` setting (FR-005-01, FR-008-01), whose default is
/// ⌃⌘V. `.none` means the user cleared the chord, so nothing is registered.
@MainActor
public protocol LibraryHotkeyPreferences {
    var openLibraryChord: ChordBinding { get }
}

public struct SettingsLibraryHotkeyPreferences: LibraryHotkeyPreferences {
    private let settings: SettingsStore

    public init(settings: SettingsStore) { self.settings = settings }

    public var openLibraryChord: ChordBinding { settings.value(SettingKeys.shortcutsOpenLibrary) }
}

/// The Toggle Shelf chord (FR-005-01, FR-006-03c) in the shape `LibraryHotkey` registers: the `shortcuts.toggleShelf`
/// setting, or none while `shelf.enabled` is off (FR-005-07). The name on the protocol says "Library" because the one
/// registration path was written first for the Library; the chord is whatever the adapter returns.
public struct SettingsShelfHotkeyPreferences: LibraryHotkeyPreferences {
    private let settings: SettingsStore

    public init(settings: SettingsStore) { self.settings = settings }

    public var openLibraryChord: ChordBinding {
        settings.value(SettingKeys.shelfEnabled) ? settings.value(SettingKeys.shortcutsToggleShelf) : ChordBinding.none
    }
}
