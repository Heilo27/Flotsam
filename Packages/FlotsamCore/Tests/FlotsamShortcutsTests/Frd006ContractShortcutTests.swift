import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShortcuts

/// FRD-006 oracle contract tests, the Toggle Shelf hotkey (OC-6002, OC-6003). The chord is the oracle's ⌘⇧9 (key code
/// 25, command+shift), pressed through the registry's fake registrar, so "reaches TextEdit" is "no live registration".
@MainActor @Suite struct Frd006ContractShortcutTests {
    private let cmdShift9 = Chord(keyCode: 25, modifiers: [.command, .shift])

    private func make() -> (ShortcutRegistry, FakeRegistrar, SettingsStore) {
        let registrar = FakeRegistrar()
        let registry = ShortcutRegistry(registrar: registrar, systemHotkeys: FakeSystemHotkeys(chords: []))
        return (registry, registrar, SettingsStore(store: InMemoryKeyValueStore()))
    }

    // OC-6002. given the Shelf enabled with Toggle Shelf on ⌘⇧9, when the Shelf is switched off, then ⌘⇧9 is no longer
    // registered (it reaches the frontmost app) and pressing it does not run the Shelf action.
    @Test("OC-6002 with the Shelf switched off, ⌘⇧9 is not registered and runs nothing")
    func oc6002_hotkeyReleasedWhenOff() {
        let (registry, registrar, settings) = make()
        var toggles = 0
        registry.setAction(.toggleShelf) { toggles += 1 }
        settings.set(ChordBinding.chord(cmdShift9), for: SettingKeys.shortcutsToggleShelf)
        registry.applyGlobalSettings(settings)
        registrar.press(cmdShift9)
        #expect(toggles == 1)

        settings.set(false, for: SettingKeys.shelfEnabled)
        registry.applyGlobalSettings(settings)
        registrar.press(cmdShift9)

        #expect(!registrar.liveChords.contains(cmdShift9))
        #expect(toggles == 1)
    }

    // OC-6003. given the Shelf was just turned off, when it is turned on again (no relaunch), then ⌘⇧9 is live again and
    // shows the Shelf: exactly one more toggle.
    @Test("OC-6003 turning the Shelf back on makes ⌘⇧9 live again with no relaunch")
    func oc6003_hotkeyBackWhenOn() {
        let (registry, registrar, settings) = make()
        var toggles = 0
        registry.setAction(.toggleShelf) { toggles += 1 }
        settings.set(ChordBinding.chord(cmdShift9), for: SettingKeys.shortcutsToggleShelf)
        settings.set(false, for: SettingKeys.shelfEnabled)
        registry.applyGlobalSettings(settings)
        registrar.press(cmdShift9)
        #expect(toggles == 0)

        settings.set(true, for: SettingKeys.shelfEnabled)
        registry.applyGlobalSettings(settings)
        registrar.press(cmdShift9)

        #expect(registrar.liveChords.contains(cmdShift9))
        #expect(toggles == 1)
    }
}
