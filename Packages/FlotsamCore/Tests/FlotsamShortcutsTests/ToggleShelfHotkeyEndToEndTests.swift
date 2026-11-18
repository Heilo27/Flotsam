import Foundation
import Testing
import FlotsamBase
import FlotsamShelf
@testable import FlotsamShortcuts

/// FR-005-07 Toggle Shelf, end to end across the two real modules: the registry's hotkey press drives the real Shelf
/// reveal machine exactly as `AppContainer.startShelf` wires it (`setAction(.toggleShelf) { toggle(.hotkey) }`), and the
/// `shelf.enabled` setting feeds both the registry (`applyGlobalSettings`) and the machine (`configure`). Visibility is
/// read from the commands the machine emits (`show`/`hide`), the layer the panel controller acts on. Expected values
/// are literals.
@MainActor @Suite("FR-005-07 worf: Toggle Shelf hotkey shows and hides the Shelf")
struct ToggleShelfHotkeyEndToEndTests {
    private let cmdJ = Chord(keyCode: 38, modifiers: .command)
    private let clock = Date(timeIntervalSinceReferenceDate: 2_000_000)

    @MainActor private final class Harness {
        let registrar = FakeRegistrar()
        let registry: ShortcutRegistry
        let settings = SettingsStore(store: InMemoryKeyValueStore())
        var machine = ShelfRevealMachine()
        /// Every command the machine has emitted, in order, as literals ("show"/"hide").
        var emitted: [String] = []
        let now: Date

        init(now: Date, chord: Chord) {
            self.now = now
            registry = ShortcutRegistry(registrar: registrar, systemHotkeys: FakeSystemHotkeys(chords: []))
            registry.setAction(.toggleShelf) { [unowned self] in self.record(machine.send(.toggle(.hotkey, screen: 0), at: self.now)) }
            settings.set(ChordBinding.chord(chord), for: SettingKeys.shortcutsToggleShelf)
            applySettings()
        }

        /// What the app does on a settings change: registry first, then the machine's `enabled`.
        func applySettings() {
            registry.applyGlobalSettings(settings)
            record(machine.send(
                .configure(enabled: settings.value(SettingKeys.shelfEnabled), placement: .rightEdge, revealOnEdgeHover: false),
                at: now))
        }

        func record(_ commands: [ShelfRevealMachine.Command]) {
            for command in commands {
                switch command {
                case .show: emitted.append("show")
                case .hide: emitted.append("hide")
                }
            }
        }
    }

    // OC-W314-001. given the Shelf enabled and Toggle Shelf bound to ⌘J, when the hotkey is pressed twice, then the first
    // press shows the Shelf and the second hides it. Red if the hotkey is not wired to the toggle, or the second press
    // re-shows instead of hiding.
    @Test("OC-W314-001 the hotkey shows the Shelf, then hides it")
    func hotkeyShowsThenHides() {
        let h = Harness(now: clock, chord: cmdJ)
        #expect(h.machine.isVisible == false)

        h.registrar.press(cmdJ)
        #expect(h.emitted == ["show"])
        #expect(h.machine.isVisible == true)

        h.registrar.press(cmdJ)
        #expect(h.emitted == ["show", "hide"])
        #expect(h.machine.isVisible == false)
    }

    // OC-W314-002. given a visible Shelf, when shelf.enabled goes off, then the hotkey is unregistered (zero live Toggle
    // Shelf chords), the Shelf is hidden, and a press does nothing. Red if the registry keeps the chord live while off.
    @Test("OC-W314-002 turning the Shelf off unregisters the hotkey and a press does nothing")
    func offUnregistersHotkey() {
        let h = Harness(now: clock, chord: cmdJ)
        h.registrar.press(cmdJ)
        let liveBefore = h.registrar.liveChords.count

        h.settings.set(false, for: SettingKeys.shelfEnabled)
        h.applySettings()
        h.registrar.press(cmdJ)

        #expect(liveBefore == 2)
        #expect(h.registrar.liveChords == [Chord(keyCode: 9, modifiers: [.control, .command])])
        #expect(h.registry.status(of: .toggleShelf) == .unbound)
        #expect(h.emitted == ["show", "hide"])
        #expect(h.machine.isVisible == false)
        #expect(h.settings.value(SettingKeys.shortcutsToggleShelf) == ChordBinding.chord(cmdJ))
    }

    // OC-W314-003. given the Shelf was turned off, when shelf.enabled goes back on, then the same chord is registered
    // again (count delta +1) and the next press shows the Shelf. Red if re-enabling does not re-register.
    @Test("OC-W314-003 turning the Shelf back on re-registers the hotkey and a press shows the Shelf")
    func onReRegistersHotkey() {
        let h = Harness(now: clock, chord: cmdJ)
        h.settings.set(false, for: SettingKeys.shelfEnabled)
        h.applySettings()
        h.registrar.press(cmdJ)
        let liveWhileOff = h.registrar.liveChords.count
        #expect(h.emitted.isEmpty)

        h.settings.set(true, for: SettingKeys.shelfEnabled)
        h.applySettings()
        h.registrar.press(cmdJ)

        #expect(liveWhileOff == 1)
        #expect(h.registrar.liveChords.count == 2)
        #expect(h.registry.status(of: .toggleShelf) == .registered)
        #expect(h.emitted == ["show"])
        #expect(h.machine.isVisible == true)
    }

    // OC-W314-004. given the Shelf disabled from the start, when the hotkey is pressed, then nothing is shown. Boundary:
    // the zero-press case emits nothing either. Red if a disabled Shelf still shows.
    @Test("OC-W314-004 a Shelf disabled from the start never shows on a press")
    func disabledFromStartNeverShows() {
        let h = Harness(now: clock, chord: cmdJ)
        h.settings.set(false, for: SettingKeys.shelfEnabled)
        h.applySettings()

        h.registrar.press(cmdJ)
        h.registrar.press(cmdJ)

        #expect(h.emitted.isEmpty)
        #expect(h.registrar.liveChords.count == 1)
    }
}
