import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShortcuts

// FRD-005 8T contract tests, slice S2 (registry and recorder: FR-005-01, FR-005-03, FR-005-04). Written from the blind
// oracle contract (.claude/oracle/frd-005-contract.json): each test asserts the contract's "then" with literal chords
// and literal catalogue text. Analogues that stay as they are: ShortcutRegistryTests.
//
// The registrar fake stands in for Carbon; a press on it is "the user pressed the chord". The App target owns what the
// package cannot see, so these parts are UNTESTABLE-AT-PACKAGE and have no fake test here:
//  - OC-5020: "hotkeys need neither Accessibility nor Input Monitoring" is a property of the real Carbon registration
//    under real TCC state. `ShortcutRegistry` takes no permission probe, so no package seam can make it refuse.
//    Missing seam: the real `RegisterEventHotKey` adapter under a denied TCC state (App/OS half).
//  - OC-5021: "the key goes to TextEdit after quit" needs the real OS hotkey table and a real frontmost app. Missing
//    seam: the real registrar's teardown at `applicationWillTerminate`.
//  - The inline error text under the recorder (`ShortcutRecorderModel.errorMessage`) and the Open Library row having no
//    clear button (`ShortcutsPane`, `allowClear: false`) are App-layer views. Here the layer below is asserted: the
//    error the registry returns, the literal catalogue text for it, and the refusal to clear.
//  - "the first press opens the Library, the second closes it" (5001) is the Library window's toggle in AppContainer;
//    here the bound action runs once per press.

private let catalogueTRGVAL004 = "That shortcut is already used in Flotsam."
private let catalogueTRGOS001 = "macOS wouldn't let Flotsam use that shortcut. Try a different one."

private extension Chord {
    static let ctrlOpt1 = Chord(keyCode: 18, modifiers: [.control, .option])
    static let ctrlOpt2 = Chord(keyCode: 19, modifiers: [.control, .option])
    static let ctrlOpt7 = Chord(keyCode: 26, modifiers: [.control, .option])
    static let ctrlOptS = Chord(keyCode: 1, modifiers: [.control, .option])
    static let ctrlOptCmdL = Chord(keyCode: 37, modifiers: [.control, .option, .command])
}

@MainActor
private final class Counters {
    var library = 0
    var saveClipboard = 0
    var toggleShelf = 0
    var items: [UUID: Int] = [:]
    func count(_ item: UUID) -> Int { items[item] ?? 0 }
}

@MainActor
private struct Rig {
    let registry: ShortcutRegistry
    let registrar: FakeRegistrar
    let counters = Counters()

    init(refusing: Set<Chord> = []) {
        registrar = FakeRegistrar()
        registrar.refused = refusing
        registry = ShortcutRegistry(registrar: registrar, systemHotkeys: FakeSystemHotkeys(chords: []))
        let counters = counters
        registry.setAction(.openLibrary) { counters.library += 1 }
        registry.setAction(.saveClipboard) { counters.saveClipboard += 1 }
        registry.setAction(.toggleShelf) { counters.toggleShelf += 1 }
    }

    func addItem(_ id: UUID) {
        let counters = counters
        registry.setAction(.item(id)) { counters.items[id, default: 0] += 1 }
    }

    /// The launch / setting-changed path of AppContainer: settings in, registry bound.
    @discardableResult func apply(_ settings: SettingsStore) -> [FlotsamError] { registry.applyGlobalSettings(settings) }
}

@MainActor @Suite struct FRD005ContractTestsRegistry {
    // MARK: OC-5001 / OC-5002

    @Test("OC-5001 fresh install: Open Library is ⌃⌘V, Save Clipboard and Toggle Shelf have no chord, no other chord is live")
    func oc5001FreshInstallDefaults() {
        // given a fresh install (an empty settings store) with the three global actions set
        let settings = SettingsStore(store: InMemoryKeyValueStore())
        let rig = Rig()
        // when the settings are applied at launch and the user presses ⌃⌘V twice
        let errors = rig.apply(settings)
        rig.registrar.press(.ctrlCmdV)
        rig.registrar.press(.ctrlCmdV)
        // then the menu shows ⌃⌘V only for Open Library, only ⌃⌘V is registered, and the action ran once per press
        let rows = Array(MenuBarModel.entries(settings: settings).prefix(4))
        #expect(
            rows == [
                .openLibrary(.chord(Chord(keyCode: 9, modifiers: [.control, .command]))),
                .saveClipboard(.none),
                .addClip(.none),
                .toggleShelf(.none),
            ])
        #expect(errors.isEmpty)
        #expect(rig.registrar.liveChords == [Chord(keyCode: 9, modifiers: [.control, .command])])
        #expect(rig.registrar.live.count == 1)
        #expect(rig.registry.chord(for: .saveClipboard) == nil)
        #expect(rig.registry.chord(for: .toggleShelf) == nil)
        #expect(rig.counters.library == 2)
        #expect(rig.counters.saveClipboard == 0)
        #expect(rig.counters.toggleShelf == 0)
    }

    @Test("OC-5002 rebinding Open Library to ⌃⌥⌘L takes effect at once, ⌃⌘V stops, and ⌃⌥⌘L survives a relaunch")
    func oc5002RebindOpenLibraryPersists() {
        // given Open Library on the default ⌃⌘V
        let store = InMemoryKeyValueStore()
        let settings = SettingsStore(store: store)
        let rig = Rig()
        rig.apply(settings)
        // when the user records ⌃⌥⌘L (the setting is written, the registry re-applied) and presses both chords
        settings.set(ChordBinding.chord(Chord(keyCode: 37, modifiers: [.control, .option, .command])), for: SettingKeys.shortcutsOpenLibrary)
        let errors = rig.apply(settings)
        rig.registrar.press(Chord(keyCode: 37, modifiers: [.control, .option, .command]))
        rig.registrar.press(Chord(keyCode: 9, modifiers: [.control, .command]))
        // then ⌃⌥⌘L fired once, ⌃⌘V did nothing, and exactly one chord is live
        #expect(errors.isEmpty)
        #expect(rig.counters.library == 1)
        #expect(rig.registrar.liveChords == [Chord(keyCode: 37, modifiers: [.control, .option, .command])])
        #expect(rig.registrar.live.count == 1)
        // when the app relaunches (a fresh settings store over the same persisted values, a fresh registry)
        let relaunched = Rig()
        relaunched.apply(SettingsStore(store: store))
        relaunched.registrar.press(Chord(keyCode: 37, modifiers: [.control, .option, .command]))
        // then ⌃⌥⌘L still opens the Library and ⌃⌘V is still not bound
        #expect(relaunched.registrar.liveChords == [Chord(keyCode: 37, modifiers: [.control, .option, .command])])
        #expect(relaunched.counters.library == 1)
        #expect(relaunched.registry.chord(for: .openLibrary) == Chord(keyCode: 37, modifiers: [.control, .option, .command]))
    }

    // MARK: OC-5003 / OC-5004 / OC-5005

    @Test("OC-5003 Delete and Backspace on the Open Library recorder are refused; the binding stays ⌃⌘V and still opens the Library")
    func oc5003OpenLibraryCannotBeCleared() {
        // given Open Library bound to ⌃⌘V
        let rig = Rig()
        rig.apply(SettingsStore(store: InMemoryKeyValueStore()))
        // when the recorder sees Backspace (51) and then forward Delete (117), both interpreted as clear, and the caller clears
        let keys = [
            RecorderKey.interpret(keyCode: 51, modifiers: []),
            RecorderKey.interpret(keyCode: 117, modifiers: []),
        ]
        let results = keys.map { _ in rig.registry.bind(.openLibrary, to: nil) }
        // then both keys read as clear, both clears are refused, and the binding, registration and action are intact
        #expect(keys == [.clear, .clear])
        #expect(results.map(\.errorCode) == [.trgVal003, .trgVal003])
        #expect(rig.registry.chord(for: .openLibrary) == Chord(keyCode: 9, modifiers: [.control, .command]))
        #expect(rig.registry.status(of: .openLibrary) == .registered)
        rig.registrar.press(Chord(keyCode: 9, modifiers: [.control, .command]))
        #expect(rig.counters.library == 1)
    }

    @Test("OC-5004 clearing Save Clipboard unbinds ⌃⌥S, and the menu row stays present with no chord")
    func oc5004ClearSaveClipboardKeepsTheMenuItem() {
        // given Save Clipboard bound to ⌃⌥S through settings
        let settings = SettingsStore(store: InMemoryKeyValueStore())
        settings.set(ChordBinding.chord(Chord(keyCode: 1, modifiers: [.control, .option])), for: SettingKeys.shortcutsSaveClipboard)
        let rig = Rig()
        rig.apply(settings)
        rig.registrar.press(.ctrlOptS)
        #expect(rig.counters.saveClipboard == 1)
        // when the user clears the binding and presses ⌃⌥S again
        settings.set(ChordBinding.none, for: SettingKeys.shortcutsSaveClipboard)
        let errors = rig.apply(settings)
        rig.registrar.press(.ctrlOptS)
        // then ⌃⌥S did nothing more, only Open Library stays registered, and the menu still lists Save Clipboard, chordless
        #expect(errors.isEmpty)
        #expect(rig.counters.saveClipboard == 1)
        #expect(rig.registry.chord(for: .saveClipboard) == nil)
        #expect(rig.registry.status(of: .saveClipboard) == .unbound)
        #expect(rig.registrar.liveChords == [Chord(keyCode: 9, modifiers: [.control, .command])])
        let rows = MenuBarModel.entries(settings: settings)
        #expect(rows.count == 14)
        #expect(Array(rows.prefix(4)) == [
            .openLibrary(.chord(Chord(keyCode: 9, modifiers: [.control, .command]))), .saveClipboard(.none), .addClip(.none),
            .toggleShelf(.none),
        ])
    }

    @Test("OC-5005 the menu shows each action's current chord and follows a change in Settings")
    func oc5005MenuLabelsFollowTheChords() {
        // given Save Clipboard on ⌃⌥S and Toggle Shelf on ⌘⇧9
        let settings = SettingsStore(store: InMemoryKeyValueStore())
        settings.set(ChordBinding.chord(Chord(keyCode: 1, modifiers: [.control, .option])), for: SettingKeys.shortcutsSaveClipboard)
        settings.set(ChordBinding.chord(Chord(keyCode: 25, modifiers: [.command, .shift])), for: SettingKeys.shortcutsToggleShelf)
        // when the user reads the menu items
        let before = Array(MenuBarModel.entries(settings: settings).prefix(4))
        // then Open Library, Save Clipboard and Toggle Shelf each carry their chord
        #expect(
            before == [
                .openLibrary(.chord(Chord(keyCode: 9, modifiers: [.control, .command]))),
                .saveClipboard(.chord(Chord(keyCode: 1, modifiers: [.control, .option]))),
                .addClip(.none),
                .toggleShelf(.chord(Chord(keyCode: 25, modifiers: [.command, .shift]))),
            ])
        // when the user changes Save Clipboard to ⌃⌥D in Settings
        settings.set(ChordBinding.chord(Chord(keyCode: 2, modifiers: [.control, .option])), for: SettingKeys.shortcutsSaveClipboard)
        // then the Save Clipboard row carries the new chord and the other two rows are unchanged
        let after = Array(MenuBarModel.entries(settings: settings).prefix(4))
        #expect(
            after == [
                .openLibrary(.chord(Chord(keyCode: 9, modifiers: [.control, .command]))),
                .saveClipboard(.chord(Chord(keyCode: 2, modifiers: [.control, .option]))),
                .addClip(.none),
                .toggleShelf(.chord(Chord(keyCode: 25, modifiers: [.command, .shift]))),
            ])
    }

    // MARK: OC-5013 / OC-5014 / OC-5015 (duplicates)

    @Test("OC-5013 assigning item A's ⌃⌥1 to item B is TRG-VAL-004 with the catalogue text; B has no hotkey; ⌃⌥1 still runs A")
    func oc5013DuplicateItemChordIsRejected() {
        // given item A on ⌃⌥1
        let rig = Rig()
        let a = UUID(), b = UUID()
        rig.addItem(a)
        rig.addItem(b)
        #expect(rig.registry.bind(.item(a), to: .ctrlOpt1).isSuccess)
        // when the user assigns ⌃⌥1 to item B
        let result = rig.registry.bind(.item(b), to: Chord(keyCode: 18, modifiers: [.control, .option]))
        // then TRG-VAL-004 with the literal text, B is unbound, one item binding remains, and a press runs A only
        #expect(result.errorCode == .trgVal004)
        if case .failure(let error) = result { #expect(FlotsamStrings.message(for: error) == catalogueTRGVAL004) }
        #expect(rig.registry.chord(for: .item(b)) == nil)
        #expect(rig.registry.status(of: .item(b)) == .unbound)
        #expect(rig.registry.itemBindingCount == 1)
        rig.registrar.press(Chord(keyCode: 18, modifiers: [.control, .option]))
        #expect(rig.counters.count(a) == 1)
        #expect(rig.counters.count(b) == 0)
    }

    @Test("OC-5014 assigning Open Library's ⌃⌘V to an item is TRG-VAL-004; the item gets no hotkey; ⌃⌘V still opens the Library")
    func oc5014ItemCannotTakeAGlobalChord() {
        // given Open Library on ⌃⌘V (registered through settings)
        let rig = Rig()
        rig.apply(SettingsStore(store: InMemoryKeyValueStore()))
        let item = UUID()
        rig.addItem(item)
        // when the user assigns ⌃⌘V to the item
        let result = rig.registry.bind(.item(item), to: Chord(keyCode: 9, modifiers: [.control, .command]))
        // then TRG-VAL-004, the item has no chord, and a press runs the Library action only
        #expect(result.errorCode == .trgVal004)
        #expect(rig.registry.chord(for: .item(item)) == nil)
        #expect(rig.registry.itemBindingCount == 0)
        rig.registrar.press(Chord(keyCode: 9, modifiers: [.control, .command]))
        #expect(rig.counters.library == 1)
        #expect(rig.counters.count(item) == 0)
    }

    @Test("OC-5015 recording item A's ⌃⌥2 for Toggle Shelf is TRG-VAL-004; Toggle Shelf is unchanged")
    func oc5015GlobalCannotTakeAnItemChord() {
        // given item A on ⌃⌥2 and Toggle Shelf bound to ⌘⇧9
        let rig = Rig()
        let a = UUID()
        rig.addItem(a)
        #expect(rig.registry.bind(.item(a), to: .ctrlOpt2).isSuccess)
        #expect(rig.registry.bind(.toggleShelf, to: Chord(keyCode: 25, modifiers: [.command, .shift])).isSuccess)
        // when the user records ⌃⌥2 for Toggle Shelf
        let result = rig.registry.bind(.toggleShelf, to: Chord(keyCode: 19, modifiers: [.control, .option]))
        // then TRG-VAL-004, Toggle Shelf is still ⌘⇧9, and ⌃⌥2 still runs only A
        #expect(result.errorCode == .trgVal004)
        #expect(rig.registry.chord(for: .toggleShelf) == Chord(keyCode: 25, modifiers: [.command, .shift]))
        rig.registrar.press(Chord(keyCode: 19, modifiers: [.control, .option]))
        #expect(rig.counters.count(a) == 1)
        #expect(rig.counters.toggleShelf == 0)
        #expect(rig.registrar.live.count == 2)
    }

    // MARK: OC-5016 .. OC-5019 (OS refusal, retry)

    @Test("OC-5016 an OS refusal of an item's ⌃⌥7 is TRG-OS-001, the binding is kept with a failed status, and other hotkeys still work")
    func oc5016OSRefusalKeepsTheBindingAndBlocksNothing() {
        // given macOS refuses ⌃⌥7; Open Library registered; another item B on ⌃⌥1
        let rig = Rig(refusing: [Chord(keyCode: 26, modifiers: [.control, .option])])
        rig.apply(SettingsStore(store: InMemoryKeyValueStore()))
        let a = UUID(), b = UUID()
        rig.addItem(a)
        rig.addItem(b)
        #expect(rig.registry.bind(.item(b), to: .ctrlOpt1).isSuccess)
        // when the user saves ⌃⌥7 on item A
        let result = rig.registry.bind(.item(a), to: Chord(keyCode: 26, modifiers: [.control, .option]))
        // then TRG-OS-001 with the literal text; A keeps ⌃⌥7 with .failed; the other two hotkeys still work
        #expect(result.errorCode == .trgOs001)
        if case .failure(let error) = result { #expect(FlotsamStrings.message(for: error) == catalogueTRGOS001) }
        #expect(rig.registry.chord(for: .item(a)) == Chord(keyCode: 26, modifiers: [.control, .option]))
        #expect(rig.registry.status(of: .item(a)) == .failed)
        #expect(rig.registrar.liveChords == [Chord(keyCode: 9, modifiers: [.control, .command]), Chord(keyCode: 18, modifiers: [.control, .option])])
        rig.registrar.press(Chord(keyCode: 9, modifiers: [.control, .command]))
        rig.registrar.press(Chord(keyCode: 18, modifiers: [.control, .option]))
        rig.registrar.press(Chord(keyCode: 26, modifiers: [.control, .option]))
        #expect(rig.counters.library == 1)
        #expect(rig.counters.count(b) == 1)
        #expect(rig.counters.count(a) == 0)
    }

    @Test("OC-5017 a ⌃⌥7 refused at one launch registers at the next launch, the failed status is gone, and it runs item A")
    func oc5017RefusedBindingRegistersAtRelaunch() {
        // given item A's ⌃⌥7 saved (the persisted wanted set) while macOS refused it
        let a = UUID()
        let wanted: [UUID: Chord] = [a: Chord(keyCode: 26, modifiers: [.control, .option])]
        let first = Rig(refusing: [Chord(keyCode: 26, modifiers: [.control, .option])])
        let firstErrors = first.registry.syncItemHotkeys(wanted) { _ in {} }
        #expect(firstErrors.map(\.code) == [.trgOs001])
        #expect(first.registry.status(of: .item(a)) == .failed)
        // when the app relaunches with the refusal gone (a fresh registrar and registry) and the user presses ⌃⌥7
        let second = Rig()
        let counters = second.counters
        let errors = second.registry.syncItemHotkeys(wanted) { id in { counters.items[id, default: 0] += 1 } }
        second.registrar.press(Chord(keyCode: 26, modifiers: [.control, .option]))
        // then nothing was refused, the badge (failed status) is gone, and A ran exactly once
        #expect(errors.isEmpty)
        #expect(second.registry.status(of: .item(a)) == .registered)
        #expect(second.registrar.liveChords == [Chord(keyCode: 26, modifiers: [.control, .option])])
        #expect(counters.count(a) == 1)
    }

    @Test("OC-5018 a ⌃⌥7 refused earlier is registered by the retry on wake; before the retry a press does nothing")
    func oc5018WakeRetryRegistersTheRefusedBinding() {
        // given item A's ⌃⌥7 saved while refused, then the refusal removed while running
        let rig = Rig(refusing: [Chord(keyCode: 26, modifiers: [.control, .option])])
        let a = UUID()
        rig.addItem(a)
        #expect(rig.registry.bind(.item(a), to: Chord(keyCode: 26, modifiers: [.control, .option])).errorCode == .trgOs001)
        // when the Mac wakes and the retry runs while still refused, then again after the refusal is removed
        let stillRefused = rig.registry.retryFailed()
        #expect(stillRefused.map(\.code) == [.trgOs001])
        #expect(rig.registry.status(of: .item(a)) == .failed)
        rig.registrar.refused = []
        let afterRemoval = rig.registry.retryFailed()
        rig.registrar.press(Chord(keyCode: 26, modifiers: [.control, .option]))
        // then the retry registered it, the status is registered, and the press ran A once
        #expect(afterRemoval.isEmpty)
        #expect(rig.registry.status(of: .item(a)) == .registered)
        #expect(rig.registrar.liveChords == [Chord(keyCode: 26, modifiers: [.control, .option])])
        #expect(rig.counters.count(a) == 1)
    }

    @Test("OC-5019 re-saving a refused ⌃⌥7 once the refusal is gone registers it, and a press runs item A")
    func oc5019ReSaveRegistersTheRefusedBinding() {
        // given item A's ⌃⌥7 saved while refused, then the refusal removed
        let rig = Rig(refusing: [Chord(keyCode: 26, modifiers: [.control, .option])])
        let a = UUID()
        rig.addItem(a)
        #expect(rig.registry.bind(.item(a), to: Chord(keyCode: 26, modifiers: [.control, .option])).errorCode == .trgOs001)
        #expect(rig.registrar.live.isEmpty)
        rig.registrar.refused = []
        // when the user re-saves ⌃⌥7 in A's editor and presses it
        let result = rig.registry.bind(.item(a), to: Chord(keyCode: 26, modifiers: [.control, .option]))
        rig.registrar.press(Chord(keyCode: 26, modifiers: [.control, .option]))
        // then the re-save is accepted (its own chord is not a duplicate), A is registered, and ran once
        #expect(result.isSuccess)
        #expect(rig.registry.status(of: .item(a)) == .registered)
        #expect(rig.registry.itemBindingCount == 1)
        #expect(rig.counters.count(a) == 1)
    }

    // MARK: OC-5022 / OC-5023 / OC-5024 (recorder)

    @Test("OC-5022 while the Save Clipboard recorder records, ⌃⌥1 and ⌃⌘V reach the recorder, not A or the Library; both are TRG-VAL-004")
    func oc5022RecordingSwallowsHotkeysAndShowsDuplicates() {
        // given item A on ⌃⌥1, Open Library on ⌃⌘V, and the Save Clipboard recorder recording
        let rig = Rig()
        rig.apply(SettingsStore(store: InMemoryKeyValueStore()))
        let a = UUID()
        rig.addItem(a)
        #expect(rig.registry.bind(.item(a), to: .ctrlOpt1).isSuccess)
        rig.registry.beginRecording()
        // when the user presses ⌃⌥1, then ⌃⌘V
        rig.registrar.press(Chord(keyCode: 18, modifiers: [.control, .option]))
        rig.registrar.press(Chord(keyCode: 9, modifiers: [.control, .command]))
        let first = rig.registry.validate(Chord(keyCode: 18, modifiers: [.control, .option]), for: .saveClipboard)
        let second = rig.registry.validate(Chord(keyCode: 9, modifiers: [.control, .command]), for: .saveClipboard)
        // then neither action ran, both are TRG-VAL-004 with the literal text, nothing was bound, and recording continues
        #expect(rig.counters.count(a) == 0)
        #expect(rig.counters.library == 0)
        #expect(first.errorCode == .trgVal004)
        #expect(second.errorCode == .trgVal004)
        if case .failure(let error) = first { #expect(FlotsamStrings.message(for: error) == catalogueTRGVAL004) }
        #expect(rig.registry.chord(for: .saveClipboard) == nil)
        #expect(rig.registrar.live.isEmpty)
    }

    @Test("OC-5023 Esc ends recording with Save Clipboard unchanged; ⌃⌥1 then pastes A and ⌃⌘V opens the Library")
    func oc5023EscapeEndsRecordingAndRestoresHotkeys() {
        // given the state of 5022: A on ⌃⌥1, Open Library on ⌃⌘V, recording in progress
        let rig = Rig()
        rig.apply(SettingsStore(store: InMemoryKeyValueStore()))
        let a = UUID()
        rig.addItem(a)
        #expect(rig.registry.bind(.item(a), to: .ctrlOpt1).isSuccess)
        rig.registry.beginRecording()
        #expect(rig.registrar.live.isEmpty)
        // when the user presses Esc (read as cancel), the recorder ends, then ⌃⌥1 and ⌃⌘V are pressed
        let key = RecorderKey.interpret(keyCode: 53, modifiers: [])
        rig.registry.endRecording()
        rig.registrar.press(Chord(keyCode: 18, modifiers: [.control, .option]))
        rig.registrar.press(Chord(keyCode: 9, modifiers: [.control, .command]))
        // then Esc read as cancel, Save Clipboard is still unbound, both hotkeys are live again and each ran once
        #expect(key == .cancel)
        #expect(rig.registry.chord(for: .saveClipboard) == nil)
        #expect(rig.registrar.liveChords == [Chord(keyCode: 18, modifiers: [.control, .option]), Chord(keyCode: 9, modifiers: [.control, .command])])
        #expect(rig.counters.count(a) == 1)
        #expect(rig.counters.library == 1)
    }

    @Test("OC-5024 Delete on the Save Clipboard recorder clears the binding; ⌃⌥S no longer saves")
    func oc5024DeleteClearsSaveClipboard() {
        // given Save Clipboard on ⌃⌥S and its recorder recording
        let rig = Rig()
        #expect(rig.registry.bind(.saveClipboard, to: Chord(keyCode: 1, modifiers: [.control, .option])).isSuccess)
        rig.registrar.press(.ctrlOptS)
        #expect(rig.counters.saveClipboard == 1)
        rig.registry.beginRecording()
        // when the user presses Delete (read as clear) and the recorder commits the clear, ending recording
        let key = RecorderKey.interpret(keyCode: 51, modifiers: [])
        let cleared = rig.registry.bind(.saveClipboard, to: nil)
        rig.registry.endRecording()
        rig.registrar.press(.ctrlOptS)
        // then the clear was accepted, there is no chord and nothing is live, and ⌃⌥S did not save again
        #expect(key == .clear)
        #expect(cleared.isSuccess)
        #expect(rig.registry.chord(for: .saveClipboard) == nil)
        #expect(rig.registry.status(of: .saveClipboard) == .unbound)
        #expect(rig.registrar.live.isEmpty)
        #expect(rig.counters.saveClipboard == 1)
    }
}
