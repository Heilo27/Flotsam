import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShortcuts

/// FR-005-07 Toggle Shelf and FR-005-06 Save Clipboard, through `ShortcutRegistry` and `SaveClipboardAction`. These
/// re-pin the three cases of the deleted ShelfHotkeyPreferencesWorf409Tests (OC-W409-001..003) against the registry
/// that replaced `SettingsShelfHotkeyPreferences`, and add the bind / unbind / rebind / press paths.
@MainActor @Suite("FR-005-07 worf: Toggle Shelf hotkey")
struct ShelfHotkeyRegistryWorfTests {
    private func make(refusing: Set<Chord> = []) -> (ShortcutRegistry, FakeRegistrar, SettingsStore) {
        let registrar = FakeRegistrar()
        registrar.refused = refusing
        let registry = ShortcutRegistry(registrar: registrar, systemHotkeys: FakeSystemHotkeys(chords: []))
        return (registry, registrar, SettingsStore(store: InMemoryKeyValueStore()))
    }

    /// OC-W409-003 / FR-006-03c. given a fresh settings store, then Toggle Shelf is unbound by default: only the Library
    /// chord is live, the status is `.unbound` and the stored default is `.none`. Red if a default chord is assigned.
    @Test("OC-W409-003 the Shelf hotkey is unbound by default")
    func defaultIsUnbound() {
        let (registry, registrar, settings) = make()

        registry.applyGlobalSettings(settings)

        #expect(registrar.liveChords == [.ctrlCmdV])
        #expect(registry.status(of: .toggleShelf) == .unbound)
        #expect(registry.chord(for: .toggleShelf) == nil)
        #expect(settings.value(SettingKeys.shortcutsToggleShelf) == ChordBinding.none)
    }

    /// OC-W409-001. given the Shelf enabled and a chord bound for Toggle Shelf, then that chord is registered next to (not
    /// instead of) the Library chord, and pressing it runs the Shelf action and not the Library action. Red if the
    /// Shelf chord replaces or collides with the Library chord, or runs the wrong action.
    @Test("OC-W409-001 an enabled Shelf with a bound chord registers that chord, not the Library chord, and press runs Toggle Shelf")
    func boundChordRegistersAndPressToggles() {
        let (registry, registrar, settings) = make()
        var shelf = 0, library = 0
        registry.setAction(.toggleShelf) { shelf += 1 }
        registry.setAction(.openLibrary) { library += 1 }
        settings.set(ChordBinding.chord(.cmdJ), for: SettingKeys.shortcutsToggleShelf)

        registry.applyGlobalSettings(settings)
        registrar.press(.cmdJ)

        #expect(registrar.liveChords == [.ctrlCmdV, .cmdJ])
        #expect(registry.chord(for: .toggleShelf) == .cmdJ)
        #expect(registry.status(of: .toggleShelf) == .registered)
        #expect(shelf == 1)
        #expect(library == 0)
    }

    /// OC-W409-002. given the Shelf disabled and a chord stored, then no Shelf hotkey is registered and pressing the chord
    /// does nothing, while the stored chord is kept. Red if `applyGlobalSettings` registers regardless of `shelfEnabled`.
    @Test("OC-W409-002 Shelf off with a bound chord registers no Shelf hotkey and keeps the stored chord")
    func shelfOffRegistersNothing() {
        let (registry, registrar, settings) = make()
        var shelf = 0
        registry.setAction(.toggleShelf) { shelf += 1 }
        settings.set(ChordBinding.chord(.cmdJ), for: SettingKeys.shortcutsToggleShelf)
        settings.set(false, for: SettingKeys.shelfEnabled)

        registry.applyGlobalSettings(settings)
        registrar.press(.cmdJ)

        #expect(registrar.liveChords == [.ctrlCmdV])
        #expect(registry.status(of: .toggleShelf) == .unbound)
        #expect(shelf == 0)
        #expect(settings.value(SettingKeys.shortcutsToggleShelf) == .chord(.cmdJ))
    }

    /// OC-WSH-004. given Shelf off after a registered chord, when Shelf is turned back on, then the same chord is live
    /// again and press works; the chord survived the off period in a fresh settings read. Red if turning Shelf off clears
    /// the stored chord, or if re-enabling does not re-register.
    @Test("OC-WSH-004 off then on restores the same chord and press works again")
    func offThenOnRestores() {
        let (registry, registrar, settings) = make()
        var shelf = 0
        registry.setAction(.toggleShelf) { shelf += 1 }
        settings.set(ChordBinding.chord(.cmdJ), for: SettingKeys.shortcutsToggleShelf)
        registry.applyGlobalSettings(settings)
        settings.set(false, for: SettingKeys.shelfEnabled)
        registry.applyGlobalSettings(settings)
        registrar.press(.cmdJ)
        #expect(shelf == 0)

        settings.set(true, for: SettingKeys.shelfEnabled)
        registry.applyGlobalSettings(settings)
        registrar.press(.cmdJ)

        #expect(registrar.liveChords == [.ctrlCmdV, .cmdJ])
        #expect(shelf == 1)
    }

    /// OC-WSH-005. given a bound Shelf chord, when the user rebinds it, then only the new chord is live, the old one no
    /// longer fires, and the new one does (count delta: still two live chords). Red if the old registration leaks.
    @Test("OC-WSH-005 rebinding swaps the chord: the old one is dead, the new one fires")
    func rebindingSwapsTheChord() {
        let (registry, registrar, _) = make()
        var shelf = 0
        registry.setAction(.toggleShelf) { shelf += 1 }
        _ = registry.bind(.openLibrary, to: .ctrlCmdV)
        _ = registry.bind(.toggleShelf, to: .cmdJ)
        let liveBefore = registrar.liveChords.count

        let result = registry.bind(.toggleShelf, to: .cmdK)
        registrar.press(.cmdJ)
        registrar.press(.cmdK)

        #expect(result.isSuccess)
        #expect(liveBefore == 2)
        #expect(registrar.liveChords == [.ctrlCmdV, .cmdK])
        #expect(registry.chord(for: .toggleShelf) == .cmdK)
        #expect(shelf == 1)
    }

    /// OC-WSH-006. given a bound Shelf chord, when it is cleared (bind nil), then nothing is live for it, the status is
    /// `.unbound` and pressing the old chord does nothing. Red if clearing leaves the registration live.
    @Test("OC-WSH-006 clearing the Shelf chord unregisters it and the press is dead")
    func clearingUnbinds() {
        let (registry, registrar, _) = make()
        var shelf = 0
        registry.setAction(.toggleShelf) { shelf += 1 }
        _ = registry.bind(.toggleShelf, to: .cmdJ)

        let result = registry.bind(.toggleShelf, to: nil)
        registrar.press(.cmdJ)

        #expect(result.isSuccess)
        #expect(registrar.liveChords == [])
        #expect(registry.status(of: .toggleShelf) == .unbound)
        #expect(shelf == 0)
    }

    /// OC-WSH-007. given the Shelf chord equals the Save Clipboard chord already bound, then the second bind is rejected
    /// with `TRG-VAL-004`, the first keeps it, and the Shelf stays unbound. Red if a duplicate across globals is accepted.
    @Test("OC-WSH-007 a chord already used by Save Clipboard cannot be the Shelf chord")
    func duplicateWithSaveClipboardIsRejected() {
        let (registry, registrar, _) = make()
        _ = registry.bind(.saveClipboard, to: .cmdK)

        let result = registry.bind(.toggleShelf, to: .cmdK)

        #expect(result.errorCode == .trgVal004)
        #expect(registry.chord(for: .saveClipboard) == .cmdK)
        #expect(registry.status(of: .toggleShelf) == .unbound)
        #expect(registrar.liveChords == [.cmdK])
    }

    /// OC-WSH-008. given the OS refuses the Shelf chord, when applying settings, then the Shelf shows `.failed` (chord
    /// kept, warning badge) while the Library hotkey is unaffected. Red if one refusal drops the other bindings.
    @Test("OC-WSH-008 an OS-refused Shelf chord fails alone and leaves the Library hotkey live")
    func refusedShelfChordDoesNotAffectLibrary() {
        let (registry, registrar, settings) = make(refusing: [.cmdJ])
        settings.set(ChordBinding.chord(.cmdJ), for: SettingKeys.shortcutsToggleShelf)

        registry.applyGlobalSettings(settings)

        #expect(registry.status(of: .toggleShelf) == .failed)
        #expect(registry.chord(for: .toggleShelf) == .cmdJ)
        #expect(registrar.liveChords == [.ctrlCmdV])
    }
}

/// FR-005-06: what the user is shown for each outcome. Expected texts are literals from the catalogue, not read back
/// from the production lookup (B2).
@MainActor
@Suite("FR-005-06 worf: Save Clipboard HUD")
struct SaveClipboardActionWorfTests {
    private struct FixedSaver: ClipboardSaver {
        let outcome: SaveClipboardOutcome
        func saveClipboardNow() async -> SaveClipboardOutcome { outcome }
    }

    private final class HUD {
        var shown: [String] = []
    }

    private func runAction(_ outcome: SaveClipboardOutcome) async -> [String] {
        let hud = HUD()
        await SaveClipboardAction(saver: FixedSaver(outcome: outcome), hud: { hud.shown.append($0) }).run()
        return hud.shown
    }

    /// OC-WSA-001. given each outcome, when the action runs, then exactly one HUD is shown with the literal text. Red if
    /// a code maps to the wrong string, the HUD is shown twice or not at all, or Concealed shows the generic message.
    @Test("OC-WSA-001 each outcome shows exactly one HUD with its own wording",
          arguments: [
              (SaveClipboardOutcome.saved, "Saved to Flotsam"),
              (SaveClipboardOutcome.rejected(FlotsamError(.capPol001, "t")), "Not saved: the app that copied it marked it private"),
              (SaveClipboardOutcome.rejected(FlotsamError(.capPol002, "t")), "Not saved: that app is on your ignored list"),
              (SaveClipboardOutcome.rejected(FlotsamError(.capVal001, "t")), "Nothing on the clipboard Flotsam can save"),
              (SaveClipboardOutcome.rejected(FlotsamError(.capOs001, "t")),
               "Flotsam couldn't read the clipboard just now. It will keep trying."),
          ])
    func eachOutcomeHasItsOwnHUD(outcome: SaveClipboardOutcome, expected: String) async {
        let shown = await runAction(outcome)

        #expect(shown == [expected])
    }

    /// OC-WSA-002. given an over-ceiling rejection carrying its limit, then the HUD names the limit through the catalogue
    /// message (not the generic fallback, not the three gate strings). Red if `message(for:)` drops the limit argument.
    @Test("OC-WSA-002 an over-limit rejection shows the catalogue text with the ceiling filled in")
    func overLimitShowsTheCeiling() async {
        let error = FlotsamError(.capLim001, "t", context: [.limitBytes: .bytes(10 * 1024 * 1024)])

        let shown = await runAction(.rejected(error))

        #expect(shown.count == 1)
        #expect(shown.first?.hasPrefix("A copy was too large to save (over ") == true)
        #expect(shown.first?.hasSuffix("). It is still on your clipboard.") == true)
        #expect(shown.first?.contains("%@") == false)
    }
}
