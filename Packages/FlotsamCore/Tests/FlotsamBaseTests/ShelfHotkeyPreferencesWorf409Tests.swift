import Foundation
import Testing
@testable import FlotsamBase

// Worf, TASK-409. FR-005-07 / FR-006-03c: the Toggle Shelf hotkey is the `shortcuts.toggleShelf` chord while
// `shelf.enabled` is on, and no chord while it is off.

private final class ShelfKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

@MainActor @Suite struct ShelfHotkeyPreferencesWorf409Tests {
    private let bound = ChordBinding(persisted: "38:9")

    // given a bound toggle chord and the Shelf on
    // red if the adapter returns the Library chord, or none, while enabled
    @Test("OC-W409-001 an enabled Shelf registers the toggleShelf chord, not the Library chord")
    func enabledReturnsToggleChord() throws {
        let settings = SettingsStore(store: ShelfKV())
        let chord = try #require(bound)
        settings.set(chord, for: SettingKeys.shortcutsToggleShelf)
        settings.set(true, for: SettingKeys.shelfEnabled)

        let result = SettingsShelfHotkeyPreferences(settings: settings).openLibraryChord

        #expect(result == chord)
        #expect(result != settings.value(SettingKeys.shortcutsOpenLibrary))
    }

    // given the same bound chord and the Shelf turned off
    // red if the hotkey stays registered while shelf.enabled is off (FR-005-07)
    @Test("OC-W409-002 a disabled Shelf has no hotkey even when a chord is bound")
    func disabledReturnsNone() throws {
        let settings = SettingsStore(store: ShelfKV())
        settings.set(try #require(bound), for: SettingKeys.shortcutsToggleShelf)
        settings.set(false, for: SettingKeys.shelfEnabled)

        #expect(SettingsShelfHotkeyPreferences(settings: settings).openLibraryChord == ChordBinding.none)
    }

    // given the Shelf on and the default (unbound) toggle chord
    // red if a chord appears from nowhere
    @Test("OC-W409-003 an enabled Shelf with the default binding has no chord")
    func defaultIsUnbound() {
        let settings = SettingsStore(store: ShelfKV())

        #expect(SettingsShelfHotkeyPreferences(settings: settings).openLibraryChord == ChordBinding.none)
    }
}
