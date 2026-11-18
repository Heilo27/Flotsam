import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShortcuts

// FRD-005 8T contract tests, slice S1 (chord validation, FR-005-02, FR-005-04, BR-7). Written from the blind oracle
// contract (.claude/oracle/frd-005-contract.json), not from the code: each test asserts the contract's "then" with
// literal chords, key codes and message text. Analogues that stay as they are: ChordValidatorTests,
// Worf436ChordUsableKeyTests.
//
// Key codes used (US ANSI): A 0, S 1, C 8, V 9, Q 12, W 13, H 4, M 46, X 7, Z 6, F 3, 3 20, 4 21, 9 25, comma 43,
// Tab 48, Space 49, Esc 53, F5 96, F6 97, Command 55, Option 58, Control 59.
//
// UNTESTABLE-AT-PACKAGE parts (no seam in the package; the App target owns them):
//  - "each is shown inline" is `ShortcutRecorderModel.errorMessage`, set from a private `handle` fed by an NSEvent
//    local monitor. Here the same message is asserted at the layer below it: the error the registry returns and the
//    catalogue text for that error, which is exactly what the recorder shows.
//  - "pressed in TextEdit" (5012, 5145) needs the real Carbon hotkey and a real frontmost app. Here a press on the
//    registrar fake reaches the bound action.
//  - "Flotsam did not quit" (5007): ⌘Q is the system's, nothing in the package can observe a quit.

private let catalogueTRGVAL003 = "Shortcuts need ⌘ or ⌃ plus a key, and can't be a reserved system shortcut."

private enum Key {
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let q: UInt16 = 12
    static let w: UInt16 = 13
    static let h: UInt16 = 4
    static let m: UInt16 = 46
    static let x: UInt16 = 7
    static let z: UInt16 = 6
    static let three: UInt16 = 20
    static let four: UInt16 = 21
    static let nine: UInt16 = 25
    static let comma: UInt16 = 43
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let f5: UInt16 = 96
    static let f6: UInt16 = 97
    static let commandKey: UInt16 = 55
    static let optionKey: UInt16 = 58
    static let controlKey: UInt16 = 59
}

@MainActor
private final class SaveCounter: ClipboardSaver {
    private(set) var calls = 0
    func saveClipboardNow() async -> SaveClipboardOutcome {
        calls += 1
        return .saved
    }
}

@MainActor @Suite struct FRD005ContractTestsChordValidation {
    private func make(system: Set<Chord> = []) -> (ShortcutRegistry, FakeRegistrar) {
        let registrar = FakeRegistrar()
        return (ShortcutRegistry(registrar: registrar, systemHotkeys: FakeSystemHotkeys(chords: system)), registrar)
    }

    /// What the recorder does with one key press up to the registry: interpret, then bind. Returns the bind result.
    private func record(_ keyCode: UInt16, _ modifiers: ChordModifiers, into id: ShortcutID, on registry: ShortcutRegistry)
        -> FlotsamResult<Void>
    {
        guard case .chord(let chord) = RecorderKey.interpret(keyCode: keyCode, modifiers: modifiers) else {
            return .failure(FlotsamError(.sysInt001, "not a chord"))
        }
        return registry.bind(id, to: chord)
    }

    private func codes(_ results: [FlotsamResult<Void>]) -> [ErrorCode?] { results.map(\.errorCode) }

    // MARK: OC-5006

    @Test("OC-5006 ⌥A, ⌥⇧A and ⇧A are each rejected TRG-VAL-003 with the catalogue text; Save Clipboard binding unchanged")
    func oc5006WithoutCommandOrControlIsRejected() {
        // given Save Clipboard already bound to ⌘K and the recorder focused
        let (registry, registrar) = make()
        #expect(registry.bind(.saveClipboard, to: .cmdK).isSuccess)
        // when the user presses ⌥A, then ⌥⇧A, then ⇧A
        let results = [
            record(Key.a, .option, into: .saveClipboard, on: registry),
            record(Key.a, [.option, .shift], into: .saveClipboard, on: registry),
            record(Key.a, .shift, into: .saveClipboard, on: registry),
        ]
        // then each is TRG-VAL-003 with the literal inline text, and the binding is still ⌘K and only ⌘K is live
        #expect(codes(results) == [.trgVal003, .trgVal003, .trgVal003])
        for case .failure(let error) in results { #expect(FlotsamStrings.message(for: error) == catalogueTRGVAL003) }
        #expect(registry.chord(for: .saveClipboard) == Chord(keyCode: 40, modifiers: .command))
        #expect(registrar.liveChords == [Chord(keyCode: 40, modifiers: .command)])
        #expect(registrar.live.count == 1)
    }

    // MARK: OC-5007

    @Test("OC-5007 ⌘Q, ⌘C, ⌘Space and ⌃Space are each rejected TRG-VAL-003; nothing saved")
    func oc5007ReservedChordsAreRejected() {
        // given an unbound Save Clipboard and the recorder focused
        let (registry, registrar) = make()
        // when the user presses ⌘Q, ⌘C, ⌘Space and ⌃Space in turn
        let results = [
            record(Key.q, .command, into: .saveClipboard, on: registry),
            record(Key.c, .command, into: .saveClipboard, on: registry),
            record(Key.space, .command, into: .saveClipboard, on: registry),
            record(Key.space, .control, into: .saveClipboard, on: registry),
        ]
        // then four TRG-VAL-003 rejections and nothing was saved or registered
        #expect(codes(results) == [.trgVal003, .trgVal003, .trgVal003, .trgVal003])
        #expect(registry.chord(for: .saveClipboard) == nil)
        #expect(registry.status(of: .saveClipboard) == .unbound)
        #expect(registrar.registerCalls == 0)
        #expect(registrar.live.isEmpty)
    }

    // MARK: OC-5008

    @Test("OC-5008 ⌘W ⌘H ⌘M ⌘Tab ⌘⌥Esc ⌘comma ⌘V ⌘X ⌘Z ⌘A are each rejected TRG-VAL-003; binding unchanged")
    func oc5008EveryReservedChordIsRejected() {
        // given Save Clipboard bound to ⌘K
        let (registry, registrar) = make()
        #expect(registry.bind(.saveClipboard, to: .cmdK).isSuccess)
        // when the user presses each of the ten reserved chords
        let pressed: [(UInt16, ChordModifiers)] = [
            (Key.w, .command), (Key.h, .command), (Key.m, .command), (Key.tab, .command),
            (Key.escape, [.command, .option]), (Key.comma, .command),
            (Key.v, .command), (Key.x, .command), (Key.z, .command), (Key.a, .command),
        ]
        let results = pressed.map { record($0.0, $0.1, into: .saveClipboard, on: registry) }
        // then all ten are TRG-VAL-003 and the binding is still ⌘K
        #expect(results.count == 10)
        #expect(codes(results) == Array(repeating: ErrorCode.trgVal003, count: 10))
        #expect(registry.chord(for: .saveClipboard) == Chord(keyCode: 40, modifiers: .command))
        #expect(registrar.liveChords == [Chord(keyCode: 40, modifiers: .command)])
    }

    // MARK: OC-5009

    @Test("OC-5009 ⌘⇧V is accepted and saved; ⌘V alone stays reserved")
    func oc5009ReservedLettersAreReservedOnlyWithCommandAlone() {
        // given ⌘⇧V is not an enabled macOS symbolic hotkey
        let (registry, registrar) = make()
        var ran = 0
        registry.setAction(.saveClipboard) { ran += 1 }
        // when the user presses ⌘⇧V
        let accepted = record(Key.v, [.command, .shift], into: .saveClipboard, on: registry)
        // then it is accepted, saved, registered, and pressing it runs the action once
        #expect(accepted.isSuccess)
        #expect(registry.chord(for: .saveClipboard) == Chord(keyCode: 9, modifiers: [.command, .shift]))
        #expect(registry.status(of: .saveClipboard) == .registered)
        registrar.press(Chord(keyCode: 9, modifiers: [.command, .shift]))
        #expect(ran == 1)
        // and the boundary: the same key with ⌘ alone is still refused, so the rule is exact-set, not letter-wide
        #expect(record(Key.v, .command, into: .toggleShelf, on: registry).errorCode == .trgVal003)
        #expect(registry.chord(for: .toggleShelf) == nil)
    }

    // MARK: OC-5010 / OC-5011

    @Test("OC-5010 ⌘⇧3 enabled in System Settings is rejected TRG-VAL-003; not saved")
    func oc5010EnabledSystemChordIsRejected() {
        // given the screenshot shortcut ⌘⇧3 is enabled
        let screenshot = Chord(keyCode: 20, modifiers: [.command, .shift])
        let (registry, registrar) = make(system: [screenshot])
        // when the user records ⌘⇧3
        let result = record(Key.three, [.command, .shift], into: .saveClipboard, on: registry)
        // then TRG-VAL-003, nothing saved or registered; a different ⌘⇧ chord (⌘⇧4, not in the set) is accepted
        #expect(result.errorCode == .trgVal003)
        #expect(registry.chord(for: .saveClipboard) == nil)
        #expect(registrar.live.isEmpty)
        #expect(record(Key.four, [.command, .shift], into: .saveClipboard, on: registry).isSuccess)
        #expect(registry.chord(for: .saveClipboard) == Chord(keyCode: 21, modifiers: [.command, .shift]))
    }

    @Test("OC-5011 ⌘⇧3 turned off in System Settings is accepted and pressing it saves the clipboard")
    func oc5011DisabledSystemChordIsAcceptedAndSaves() async {
        // given ⌘⇧3 is off, so the system set is empty, and Save Clipboard's action is the real SaveClipboardAction
        let (registry, registrar) = make(system: [])
        let saver = SaveCounter()
        var hud: [String] = []
        var inFlight: Task<Void, Never>?
        let action = SaveClipboardAction(saver: saver, hud: { hud.append($0) })
        registry.setAction(.saveClipboard) { inFlight = Task { @MainActor in await action.run() } }
        // when the user records ⌘⇧3 for Save Clipboard and presses it
        let result = record(Key.three, [.command, .shift], into: .saveClipboard, on: registry)
        registrar.press(Chord(keyCode: 20, modifiers: [.command, .shift]))
        await inFlight?.value
        // then it was accepted and saved, and the clipboard save ran exactly once with the saved HUD
        #expect(result.isSuccess)
        #expect(registry.chord(for: .saveClipboard) == Chord(keyCode: 20, modifiers: [.command, .shift]))
        #expect(saver.calls == 1)
        #expect(hud == ["Saved to Flotsam"])
    }

    // MARK: OC-5012

    @Test("OC-5012 ⌃⌥A (Save Clipboard), ⌘⇧9 (Toggle Shelf) and ⌃⌘F5 (item) are accepted, saved, and each fires only its own action")
    func oc5012ThreeValidChordsAreAcceptedAndFire() {
        // given no chords in use besides defaults
        let (registry, registrar) = make()
        let item = UUID()
        var fired: [String] = []
        registry.setAction(.saveClipboard) { fired.append("save") }
        registry.setAction(.toggleShelf) { fired.append("shelf") }
        registry.setAction(.item(item)) { fired.append("item") }
        // when the user records the three chords
        let results = [
            record(Key.a, [.control, .option], into: .saveClipboard, on: registry),
            record(Key.nine, [.command, .shift], into: .toggleShelf, on: registry),
            record(Key.f5, [.control, .command], into: .item(item), on: registry),
        ]
        // then all three are accepted and saved, three live registrations, and each press fires exactly its own action
        #expect(codes(results) == [nil, nil, nil])
        #expect(registry.chord(for: .saveClipboard) == Chord(keyCode: 0, modifiers: [.control, .option]))
        #expect(registry.chord(for: .toggleShelf) == Chord(keyCode: 25, modifiers: [.command, .shift]))
        #expect(registry.chord(for: .item(item)) == Chord(keyCode: 96, modifiers: [.control, .command]))
        #expect(registrar.live.count == 3)
        registrar.press(Chord(keyCode: 0, modifiers: [.control, .option]))
        #expect(fired == ["save"])
        registrar.press(Chord(keyCode: 25, modifiers: [.command, .shift]))
        #expect(fired == ["save", "shelf"])
        registrar.press(Chord(keyCode: 96, modifiers: [.control, .command]))
        #expect(fired == ["save", "shelf", "item"])
    }

    // MARK: OC-5025 / OC-5026

    @Test("OC-5025 while recording, ⌥A is rejected TRG-VAL-003 and recording continues; ⌃⌥S is then recorded and saved")
    func oc5025RejectedChordKeepsRecordingThenValidChordIsSaved() {
        // given Save Clipboard bound to ⌘K, then recording begins (every global hotkey comes off)
        let (registry, registrar) = make()
        #expect(registry.bind(.saveClipboard, to: .cmdK).isSuccess)
        registry.beginRecording()
        #expect(registrar.live.isEmpty)
        // when the user presses ⌥A
        let rejected = registry.validate(Chord(keyCode: 0, modifiers: .option), for: .saveClipboard)
        // then TRG-VAL-003 with the inline text, nothing changed, and the registry is still recording (hotkeys still off)
        #expect(rejected.errorCode == .trgVal003)
        if case .failure(let error) = rejected { #expect(FlotsamStrings.message(for: error) == catalogueTRGVAL003) }
        #expect(registry.chord(for: .saveClipboard) == Chord(keyCode: 40, modifiers: .command))
        #expect(registrar.live.isEmpty)
        // when the user then presses ⌃⌥S and the recorder commits it, then recording ends
        let accepted = registry.bind(.saveClipboard, to: Chord(keyCode: 1, modifiers: [.control, .option]))
        registry.endRecording()
        // then ⌃⌥S is saved and is the only live chord (⌘K is gone)
        #expect(accepted.isSuccess)
        #expect(registry.chord(for: .saveClipboard) == Chord(keyCode: 1, modifiers: [.control, .option]))
        #expect(registrar.liveChords == [Chord(keyCode: 1, modifiers: [.control, .option])])
    }

    // Partial: the contract's "then" is that a lone modifier press is not recorded at all, because the recorder only
    // listens for key-down (App layer, `ShortcutRecorderModel`'s NSEvent `.keyDown` monitor, which has no package seam).
    // What the package can prove is the second line of defence: if a modifier key code did reach validation it is
    // never a usable chord, so nothing is saved and recording stays on. The key-down filter itself is UNTESTABLE-AT-PACKAGE.
    @Test("OC-5026 (validator layer only) a lone ⌘ or ⌃⌥ is never recordable: rejected TRG-VAL-003, binding unchanged, still recording")
    func oc5026ModifierOnlyIsNeverARecordableChord() {
        // given Save Clipboard bound to ⌘K and recording begun
        let (registry, registrar) = make()
        #expect(registry.bind(.saveClipboard, to: .cmdK).isSuccess)
        registry.beginRecording()
        // when ⌘ alone, then ⌃⌥ alone reach the recorder as chords
        let commandAlone = registry.validate(Chord(keyCode: Key.commandKey, modifiers: .command), for: .saveClipboard)
        let controlOption = registry.validate(Chord(keyCode: Key.optionKey, modifiers: [.control, .option]), for: .saveClipboard)
        let controlKey = registry.validate(Chord(keyCode: Key.controlKey, modifiers: .control), for: .saveClipboard)
        // then every one is rejected, the binding is unchanged and the hotkeys are still off (recording continues)
        #expect(commandAlone.errorCode == .trgVal003)
        #expect(controlOption.errorCode == .trgVal003)
        #expect(controlKey.errorCode == .trgVal003)
        #expect(registry.chord(for: .saveClipboard) == Chord(keyCode: 40, modifiers: .command))
        #expect(registrar.live.isEmpty)
        registry.endRecording()
        #expect(registrar.liveChords == [Chord(keyCode: 40, modifiers: .command)])
    }

    // MARK: OC-5144 / OC-5145 (BR-7)

    @Test("OC-5144 F5, ⇧F5 and ⌥F5 are each rejected TRG-VAL-003; nothing saved")
    func oc5144FunctionKeysNeedCommandOrControl() {
        // given an item with no hotkey and the recorder focused
        let (registry, registrar) = make()
        let item = UUID()
        // when the user presses F5 alone, then ⇧F5, then ⌥F5
        let results = [
            record(Key.f5, [], into: .item(item), on: registry),
            record(Key.f5, .shift, into: .item(item), on: registry),
            record(Key.f5, .option, into: .item(item), on: registry),
        ]
        // then three rejections, no binding, no registration
        #expect(codes(results) == [.trgVal003, .trgVal003, .trgVal003])
        #expect(registry.chord(for: .item(item)) == nil)
        #expect(registry.itemBindingCount == 0)
        #expect(registrar.registerCalls == 0)
    }

    @Test("OC-5145 ⌃F5 and, on another item, ⌘F6 are accepted and each fires its own item's action")
    func oc5145FunctionKeysWithCommandOrControlAreAccepted() {
        // given two items and the recorder focused
        let (registry, registrar) = make()
        let first = UUID()
        let second = UUID()
        var fired: [UUID] = []
        registry.setAction(.item(first)) { fired.append(first) }
        registry.setAction(.item(second)) { fired.append(second) }
        // when the user records ⌃F5 on the first and ⌘F6 on the second
        let results = [
            record(Key.f5, .control, into: .item(first), on: registry),
            record(Key.f6, .command, into: .item(second), on: registry),
        ]
        // then both are accepted, two item bindings exist, and each press fires exactly its own item
        #expect(codes(results) == [nil, nil])
        #expect(registry.itemBindingCount == 2)
        #expect(registry.chord(for: .item(first)) == Chord(keyCode: 96, modifiers: .control))
        #expect(registry.chord(for: .item(second)) == Chord(keyCode: 97, modifiers: .command))
        registrar.press(Chord(keyCode: 96, modifiers: .control))
        #expect(fired == [first])
        registrar.press(Chord(keyCode: 97, modifiers: .command))
        #expect(fired == [first, second])
    }
}
