import Foundation
import Testing
@testable import FlotsamBase

/// Counts `onInvalid` calls the way the composition root raises SET-DAT-001 (FR-008-02): one entry per call.
private final class InvalidRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func record(_ name: String) { lock.withLock { names.append(name) } }
    var calls: [String] { lock.withLock { names } }
}

/// A store that drops every write (a failing defaults domain), so the write-back cannot be what limits the notice count.
private final class WriteDroppingStore: KeyValueStore, @unchecked Sendable {
    private let values: [String: String]
    init(_ values: [String: String]) { self.values = values }
    func string(forKey key: String) -> String? { values[key] }
    func setString(_ value: String, forKey key: String) {}
    func removeValue(forKey key: String) {}
}

/// TASK-436 (Worf, blind). OC-8011 (corrupt value is overwritten with the default, key not removed) and OC-8016
/// (an unusable hotkey key code is invalid, resets to control-command-V, raises SET-DAT-001 once).
/// Every expected value is a literal; none reads the registry default or the validator under test.
@Suite struct Worf436SettingsRecoveryTests {
    // MARK: OC-8011, a corrupt value for every settings type

    /// Name, corrupt stored text, literal persisted default.
    private static let corruptCases: [(name: String, corrupt: String, defaultText: String)] = [
        ("storage.retention", "d45", "d30"),
        ("storage.retention", "", "d30"),
        ("storage.imageBudget", "huge", "gib2"),
        ("storage.imageQuality", "ultra", "original"),
        ("capture.mode", "bogus", "active"),
        ("shelf.placement", "topEdge", "rightEdge"),
        ("library.sort", "sideways", "recent"),
        ("library.viewMode", "carousel", "list"),
        ("settings.lastPane", "advanced", "general"),
        ("screenshots.enabled", "maybe", "true"),
        ("shelf.enabled", "2", "true"),
        ("shelf.revealOnEdgeHover", "yes", "false"),
        ("triggers.enabled", "TRUE ", "true"),
        ("onboarding.completed", "done", "false"),
        ("shortcuts.openLibrary", "garbage", "9:3"),
        ("shortcuts.saveClipboard", "garbage", "none"),
        ("shortcuts.toggleShelf", "9:", "none"),
        ("library.panelSize", "axb", "760.0x480.0"),
        ("library.panelSize", "0x0", "760.0x480.0"),
        ("library.panelSize", "-5x300", "760.0x480.0"),
        ("library.panelSize", "nanx300", "760.0x480.0"),
        ("library.panelSize", "infx300", "760.0x480.0"),
        ("library.compactPanelSize", "0x0", "520.0x520.0"),
        ("library.compactPanelSize", "nanx300", "520.0x520.0"),
        ("library.layout", "tiny", "standard"),
        ("library.layout", "COMPACT", "standard"),
        ("screenshots.folderOverride", "!!!not base64!!!", ""),
        ("screenshots.folderOverride", "AAAA", ""),  // decodes, but is not a resolvable bookmark
        ("privacy.ignoredApps", "not json", "DEFAULT-IGNORED"),
        ("privacy.ignoredApps", "[\"has space\"]", "DEFAULT-IGNORED"),
        ("privacy.ignoredApps", "[\"\"]", "DEFAULT-IGNORED"),
        ("triggers.excludedApps", "{\"a\":1}", "DEFAULT-EXCLUDED"),
    ]

    /// Reads `name` through the typed registry key. A switch keeps this on the public API, never a raw string read.
    private func read(_ name: String, in settings: SettingsStore) -> (persisted: String, recovered: Bool) {
        func go<V: SettingValue>(_ key: SettingKey<V>) -> (String, Bool) {
            let reading = settings.read(key)
            return (reading.value.persisted, reading.recoveredFromInvalid)
        }
        switch name {
        case "storage.retention": return go(SettingKeys.storageRetention)
        case "storage.imageBudget": return go(SettingKeys.storageImageBudget)
        case "storage.imageQuality": return go(SettingKeys.storageImageQuality)
        case "capture.mode": return go(SettingKeys.captureMode)
        case "shelf.placement": return go(SettingKeys.shelfPlacement)
        case "library.sort": return go(SettingKeys.librarySort)
        case "library.viewMode": return go(SettingKeys.libraryViewMode)
        case "settings.lastPane": return go(SettingKeys.settingsLastPane)
        case "screenshots.enabled": return go(SettingKeys.screenshotsEnabled)
        case "shelf.enabled": return go(SettingKeys.shelfEnabled)
        case "shelf.revealOnEdgeHover": return go(SettingKeys.shelfRevealOnEdgeHover)
        case "triggers.enabled": return go(SettingKeys.triggersEnabled)
        case "onboarding.completed": return go(SettingKeys.onboardingCompleted)
        case "shortcuts.openLibrary": return go(SettingKeys.shortcutsOpenLibrary)
        case "shortcuts.saveClipboard": return go(SettingKeys.shortcutsSaveClipboard)
        case "shortcuts.toggleShelf": return go(SettingKeys.shortcutsToggleShelf)
        case "library.panelSize": return go(SettingKeys.libraryPanelSize)
        case "library.compactPanelSize": return go(SettingKeys.libraryCompactPanelSize)
        case "library.layout": return go(SettingKeys.libraryLayout)
        case "screenshots.folderOverride": return go(SettingKeys.screenshotsFolderOverride)
        case "privacy.ignoredApps": return go(SettingKeys.privacyIgnoredApps)
        case "triggers.excludedApps": return go(SettingKeys.triggersExcludedApps)
        default: Issue.record("unmapped key \(name)"); return ("", false)
        }
    }

    /// Lists compare by membership: the default text is long, so assert two literal members instead of the JSON.
    private func isDefault(_ persisted: String, _ literal: String) -> Bool {
        switch literal {
        case "DEFAULT-IGNORED": persisted == "[]"  // empty since TASK-498 (FR-008-11)
        case "DEFAULT-EXCLUDED": persisted.contains("com.apple.Terminal") && persisted.contains("com.vmware.fusion")
        default: persisted == literal
        }
    }

    /// OC-8011. given a corrupt stored value of each settings type, when it is read, then the default is returned,
    /// flagged recovered, the key now HOLDS the default (not absent: `defaults read` shows it), and SET-DAT-001 fires once.
    /// Red if recovery removes the key, returns the corrupt text, skips the flag, or skips the callback.
    @Test(arguments: corruptCases.indices)
    func corruptValueIsOverwrittenWithDefaultNotRemoved(index: Int) {
        let c = Self.corruptCases[index]
        let raw = MemoryKeyValueStore()
        raw.setString(c.corrupt, forKey: c.name)
        let invalid = InvalidRecorder()
        let settings = SettingsStore(store: raw, onInvalid: { invalid.record($0) })

        let first = read(c.name, in: settings)
        #expect(isDefault(first.persisted, c.defaultText), "\(c.name) <- \(c.corrupt): got \(first.persisted)")
        #expect(first.recovered)
        #expect(invalid.calls == [c.name])

        let stored = raw.string(forKey: c.name)
        #expect(stored != nil, "recovery must write the default back, not remove the key")
        #expect(stored != c.corrupt)
        if let stored { #expect(isDefault(stored, c.defaultText)) }

        // A second read in the same launch: same default, no second notice. A fresh store (next launch) finds a clean key.
        _ = read(c.name, in: settings)
        #expect(invalid.calls.count == 1)
        let relaunch = InvalidRecorder()
        let fresh = SettingsStore(store: raw, onInvalid: { relaunch.record($0) })
        let third = read(c.name, in: fresh)
        #expect(isDefault(third.persisted, c.defaultText))
        #expect(third.recovered == false)
        #expect(relaunch.calls.isEmpty)
    }

    /// OC-8011 literal. given storage.retention 'd45', then the user sees 30 days and `defaults read` shows d30.
    @Test func retentionD45BecomesD30InTheStore() {
        let raw = MemoryKeyValueStore()
        raw.setString("d45", forKey: "storage.retention")
        let invalid = InvalidRecorder()
        let settings = SettingsStore(store: raw, onInvalid: { invalid.record($0) })
        #expect(settings.value(SettingKeys.storageRetention) == .d30)
        #expect(raw.string(forKey: "storage.retention") == "d30")
        #expect(invalid.calls == ["storage.retention"])
    }

    /// Negative: an absent key and a valid value are not corruption. No write, no notice, not flagged.
    @Test func absentAndValidValuesRaiseNothingAndAreNotRewritten() {
        let raw = MemoryKeyValueStore()
        raw.setString("y1", forKey: "storage.retention")
        let invalid = InvalidRecorder()
        let settings = SettingsStore(store: raw, onInvalid: { invalid.record($0) })

        let valid = settings.read(SettingKeys.storageRetention)
        #expect(valid.value == .y1)
        #expect(valid.recoveredFromInvalid == false)
        #expect(raw.string(forKey: "storage.retention") == "y1")

        let absent = settings.read(SettingKeys.storageImageBudget)
        #expect(absent.value == .gib2)
        #expect(absent.recoveredFromInvalid == false)
        #expect(raw.string(forKey: "storage.imageBudget") == nil)
        #expect(invalid.calls.isEmpty)
    }

    /// OC-8011 identity: two corrupt keys raise one notice EACH, and a healthy neighbour is untouched.
    @Test func twoCorruptKeysRaiseOneNoticeEachAndSurvivorKeepsValue() {
        let raw = MemoryKeyValueStore()
        raw.setString("d45", forKey: "storage.retention")
        raw.setString("huge", forKey: "storage.imageBudget")
        raw.setString("efficient", forKey: "storage.imageQuality")
        let invalid = InvalidRecorder()
        let settings = SettingsStore(store: raw, onInvalid: { invalid.record($0) })
        for _ in 0..<3 {
            _ = settings.value(SettingKeys.storageRetention)
            _ = settings.value(SettingKeys.storageImageBudget)
            _ = settings.value(SettingKeys.storageImageQuality)
        }
        #expect(invalid.calls.sorted() == ["storage.imageBudget", "storage.retention"])
        #expect(raw.string(forKey: "storage.imageQuality") == "efficient")
    }

    /// SET-DAT-001 once per key per launch even when the write-back is lost: the hub's own dedup must hold, not the
    /// side effect of the key becoming valid. Red if the first-time guard is removed.
    @Test func noticeIsOncePerKeyEvenIfTheWriteBackIsLost() {
        let invalid = InvalidRecorder()
        let settings = SettingsStore(
            store: WriteDroppingStore(["shortcuts.openLibrary": "9999:3", "storage.retention": "d45"]),
            onInvalid: { invalid.record($0) })
        for _ in 0..<4 {
            #expect(settings.value(SettingKeys.shortcutsOpenLibrary) == controlCommandV)
            #expect(settings.value(SettingKeys.storageRetention) == .d30)
        }
        #expect(invalid.calls.sorted() == ["shortcuts.openLibrary", "storage.retention"])
    }

    // MARK: OC-8016, unusable hotkey key code

    /// Literal usable key codes per FR-005-02 (b): letters, digits, punctuation (0...51 except the gap at 10),
    /// Escape 53, F1-F20, and the four arrows. Everything else, including every modifier and fn code, is unusable.
    private static let usableKeyCodes: Set<UInt16> = {
        var s = Set<UInt16>(0...51)
        s.remove(10)
        s.formUnion([53, 123, 124, 125, 126])
        s.formUnion([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90])
        return s
    }()

    private func openLibrary(storing text: String) -> (value: ChordBinding, recovered: Bool, stored: String?, notices: [String]) {
        let raw = MemoryKeyValueStore()
        raw.setString(text, forKey: "shortcuts.openLibrary")
        let invalid = InvalidRecorder()
        let settings = SettingsStore(store: raw, onInvalid: { invalid.record($0) })
        let r = settings.read(SettingKeys.shortcutsOpenLibrary)
        return (r.value, r.recoveredFromInvalid, raw.string(forKey: "shortcuts.openLibrary"), invalid.calls)
    }

    private let controlCommandV = ChordBinding.chord(Chord(keyCode: 9, modifiers: [.control, .command]))

    /// OC-8016. given key code 9999 stored, then Open Library reads control-command-V, shows it that way, the key
    /// holds "9:3", and exactly one SET-DAT-001 is raised. Red if hasUsableKey is dropped from the stored-data rule.
    @Test func keyCode9999ResetsToControlCommandVWithOneNotice() {
        let r = openLibrary(storing: "9999:3")
        #expect(r.value == controlCommandV)
        if case .chord(let chord) = r.value { #expect(chord.displayString == "⌃⌘V") } else { Issue.record("expected a chord") }
        #expect(r.recovered)
        #expect(r.stored == "9:3")
        #expect(r.notices == ["shortcuts.openLibrary"])
    }

    /// OC-8016 boundaries. given each key code 0...200 plus 65535 (UInt16 max) with control+command, then it is kept
    /// exactly when the literal FR-005-02 (b) set says so, and otherwise reset with one notice.
    @Test func everyKeyCodeBoundaryIsKeptOrResetPerTheLiteralSet() {
        var wrong: [UInt16] = []
        for code in Array(0...200) + [65535] {
            let k = UInt16(code)
            let r = openLibrary(storing: "\(k):3")
            let usable = Self.usableKeyCodes.contains(k)
            let ok: Bool
            if usable {
                ok = r.value == .chord(Chord(keyCode: k, modifiers: [.control, .command])) && !r.recovered && r.notices.isEmpty && r.stored == "\(k):3"
            } else {
                ok = r.value == controlCommandV && r.recovered && r.notices.count == 1 && r.stored == "9:3"
            }
            if !ok { wrong.append(k) }
        }
        #expect(wrong.isEmpty, "wrong handling for key codes \(wrong)")
    }

    /// OC-8016 boundaries beyond UInt16: 65536 and a negative or garbled code cannot parse, so they are invalid too.
    @Test func unparseableKeyCodesAndModifierTextAreInvalid() {
        for text in ["65536:3", "-1:3", "9.5:3", "abc:3", ":3", "9:256", "9:-1", "9", "9:3:1", "", ":", "9:x", " 9:3"] {
            let r = openLibrary(storing: text)
            #expect(r.value == controlCommandV, "\(text)")
            #expect(r.recovered, "\(text)")
            #expect(r.stored == "9:3", "\(text)")
            #expect(r.notices.count == 1, "\(text)")
        }
    }

    /// Modifier-only chords: a modifier or fn key code is never a shortcut key, even with every modifier flag set.
    @Test func modifierOnlyChordsAreInvalid() {
        for code in 54...63 {
            for mods in [1, 2, 3, 15] {
                let r = openLibrary(storing: "\(code):\(mods)")
                #expect(r.value == controlCommandV, "\(code):\(mods)")
                #expect(r.recovered, "\(code):\(mods)")
                #expect(r.notices.count == 1, "\(code):\(mods)")
            }
        }
    }

    /// FR-005-02 (a) on stored data: a usable key with no command or control is invalid; with command or control kept.
    @Test func usableKeyNeedsCommandOrControl() {
        for mods in [0, 4, 8, 12, 16] {  // none, option, shift, option+shift, stray unknown bit
            let r = openLibrary(storing: "9:\(mods)")
            #expect(r.value == controlCommandV, "9:\(mods)")
            #expect(r.recovered, "9:\(mods)")
            #expect(r.notices.count == 1, "9:\(mods)")
        }
        for mods in [1, 2, 3, 5, 9, 15] {
            let r = openLibrary(storing: "9:\(mods)")
            #expect(r.value == .chord(Chord(keyCode: 9, modifiers: ChordModifiers(rawValue: UInt8(mods)))), "9:\(mods)")
            #expect(!r.recovered, "9:\(mods)")
            #expect(r.notices.isEmpty, "9:\(mods)")
        }
    }

    /// Unbound is a legal stored value: "none" is neither reset nor reported.
    @Test func noneIsValidForOpenLibraryAndNotReported() {
        let r = openLibrary(storing: "none")
        #expect(r.value == ChordBinding.none)
        #expect(!r.recovered)
        #expect(r.stored == "none")
        #expect(r.notices.isEmpty)
    }

    /// SET-DAT-001 exactly once per key per launch, over many reads; a second hotkey key counts separately and
    /// resets to its own default (unbound), not to control-command-V. A healthy third key stays untouched.
    @Test func noticeIsOncePerKeyAndEachHotkeyResetsToItsOwnDefault() {
        let raw = MemoryKeyValueStore()
        raw.setString("9999:3", forKey: "shortcuts.openLibrary")
        raw.setString("9999:3", forKey: "shortcuts.saveClipboard")
        raw.setString("1:3", forKey: "shortcuts.toggleShelf")
        let invalid = InvalidRecorder()
        let settings = SettingsStore(store: raw, onInvalid: { invalid.record($0) })
        for _ in 0..<5 {
            #expect(settings.value(SettingKeys.shortcutsOpenLibrary) == controlCommandV)
            #expect(settings.value(SettingKeys.shortcutsSaveClipboard) == ChordBinding.none)
            #expect(settings.value(SettingKeys.shortcutsToggleShelf) == .chord(Chord(keyCode: 1, modifiers: [.control, .command])))
        }
        #expect(invalid.calls.sorted() == ["shortcuts.openLibrary", "shortcuts.saveClipboard"])
        #expect(raw.string(forKey: "shortcuts.saveClipboard") == "none")
        #expect(raw.string(forKey: "shortcuts.toggleShelf") == "1:3")
    }

    // MARK: Chord.hasUsableKey, the one home (public API)

    /// Direct check of the shared rule against the literal set, 0...300 plus max.
    @Test func hasUsableKeyMatchesLiteralSet() {
        var wrong: [UInt16] = []
        for code in Array(0...300) + [65535] {
            let k = UInt16(code)
            if Chord(keyCode: k, modifiers: .command).hasUsableKey != Self.usableKeyCodes.contains(k) { wrong.append(k) }
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    // MARK: OC-8127, modifier display order for every combination

    /// given each of the 16 modifier subsets on V, then glyphs read control, option, shift, command. Literal table.
    @Test func modifiersDisplayInControlOptionShiftCommandOrderForAll16Combinations() {
        let expected: [UInt8: String] = [
            0: "V", 1: "⌘V", 2: "⌃V", 3: "⌃⌘V", 4: "⌥V", 5: "⌥⌘V", 6: "⌃⌥V", 7: "⌃⌥⌘V",
            8: "⇧V", 9: "⇧⌘V", 10: "⌃⇧V", 11: "⌃⇧⌘V", 12: "⌥⇧V", 13: "⌥⇧⌘V", 14: "⌃⌥⇧V", 15: "⌃⌥⇧⌘V",
        ]
        #expect(expected.count == 16)
        for (bits, text) in expected {
            let chord = Chord(keyCode: 9, modifiers: ChordModifiers(rawValue: bits))
            #expect(chord.displayString == text, "bits \(bits)")
        }
    }

    /// FRD-008 FR-008-16: Toggle Shelf at command+shift on 9 reads ⇧⌘9; Save Clipboard command+option on S reads ⌥⌘S.
    @Test func frdWorkedExamplesRender() {
        #expect(Chord(keyCode: 25, modifiers: [.command, .shift]).displayString == "⇧⌘9")
        #expect(Chord(keyCode: 1, modifiers: [.command, .option]).displayString == "⌥⌘S")
        #expect(Chord(keyCode: 49, modifiers: [.control]).displayString == "⌃Space")
    }
}
