import AppKit
import FlotsamBase
import FlotsamShortcuts
import FlotsamStorage
import Foundation
import GRDB
import Testing
@testable import FlotsamStorage

// Worf, TASK-318 (FR-005-09, AC-005-08), blind. The editor model and its recorder are the App-target sources
// themselves (symlinked into this target), driven against a real GRDB database. Expected values are literals;
// persisted state is read back through a SECOND database instance opened on the same folder (TEST-DOCTRINE B4).
// Oracle ids: .claude/oracle/frd-005-contract.json OC-5054 to OC-5061.

// MARK: Rig

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
private final class StubRegistrar: HotkeyRegistrar {
    var refused: Set<Chord> = []
    private var next: UInt32 = 1
    func register(_ chord: Chord, handler: @escaping @MainActor () -> Void) -> FlotsamResult<HotkeyRegistration> {
        if refused.contains(chord) { return .failure(FlotsamError(.trgOs001, "refused by test")) }
        defer { next += 1 }
        return .success(HotkeyRegistration(rawValue: next))
    }
    func unregister(_ registration: HotkeyRegistration) {}
    func unregisterAll() {}
}

private let cmdK = Chord(keyCode: 40, modifiers: .command)
private let cmdJ = Chord(keyCode: 38, modifiers: .command)
private let cmdL = Chord(keyCode: 37, modifiers: .command)

private func uid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

@MainActor
private final class Rig {
    let root: URL
    let database: FlotsamDatabase
    let registry: ShortcutRegistry
    let registrar = StubRegistrar()
    let didSave = Box(0)
    let reports = Box<[FlotsamError]>([])
    let huds = Box<[String]>([])

    static func make() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-worf5-\(UUID().uuidString)")
        let database = try await FlotsamDatabase.open(folder: root).get()
        return Rig(root: root, database: database)
    }

    private init(root: URL, database: FlotsamDatabase) {
        self.root = root
        self.database = database
        registry = ShortcutRegistry(registrar: registrar)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func seed(_ n: Int, kind: ItemKind = .text, text: String? = nil, trigger: String? = nil, hotkey: Chord? = nil) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let body = text ?? (kind == .text || kind == .link ? "item \(n)" : nil)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize,
                                      pinned, updatedAt, hotkeyCode, hotkeyModifiers, "trigger")
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?)
                    """,
                arguments: [
                    uid(n).uuidString, kind.rawValue, now, now, "key-\(n)", body, body ?? "", now,
                    hotkey.map { Int($0.keyCode) }, hotkey.map { Int($0.modifiers.rawValue) }, trigger,
                ])
        }
    }

    func model(_ n: Int) -> ItemBindingsEditorModel {
        let didSave = didSave, reports = reports, huds = huds
        return ItemBindingsEditorModel(
            itemId: uid(n),
            services: ItemBindingsEditorServices(
                database: database, registry: registry,
                didSaveTrigger: { didSave.value += 1 },
                report: { reports.value.append($0) },
                hud: { huds.value.append($0) }))
    }

    func loaded(_ n: Int) async -> ItemBindingsEditorModel {
        let m = model(n)
        await m.load()
        return m
    }

    /// What is stored, read through a second database instance (not the one the model wrote through).
    func stored() async throws -> ItemBindings {
        let fresh = try await FlotsamDatabase.open(folder: root).get()
        return try await fresh.itemBindings().get()
    }

    func rowCount() async throws -> Int {
        try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") ?? -1 }
    }
}

/// Feeds one key-down through `NSApplication.sendEvent`, which is what runs the recorder's local monitor. In-process
/// only: no event tap, no system event is posted.
@MainActor
private func pressInProcess(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
    _ = NSApplication.shared
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: keyCode)
    if let event { NSApplication.shared.sendEvent(event) }
}

private let msgInvalid = "Triggers start with a symbol (like ;), have 2 to 24 characters and contain no spaces."
private let msgDuplicate = "That trigger is already used by another item."
private let msgChordTaken = "That shortcut is already used in Flotsam."
private let msgUnknownVariable = "An unknown variable was left as plain text."

// MARK: Which kinds are offered a trigger (OC-5054, OC-5055)

@MainActor
@Suite struct WorfEditorKindTests {
    // OC-5054/5055. Breaks if isTextBearing or the editor's triggerOffered wiring changes for any kind.
    @Test func triggerOfferedExactlyForTheTextBearingKinds() async throws {
        let offered = ["text", "richText", "link", "color", "phone", "email"]
        let notOffered = ["image", "screenshot", "file", "folder", "bundle"]
        for (index, raw) in (offered + notOffered).enumerated() {
            let rig = try await Rig.make()
            defer { rig.cleanUp() }
            try await rig.seed(index + 1, kind: ItemKind(rawValue: raw)!)
            let model = await rig.loaded(index + 1)
            #expect(model.phase == .ready, "kind \(raw)")
            #expect(model.triggerOffered == offered.contains(raw), "kind \(raw)")
        }
        #expect(ItemKind.allCases.count == 11)
    }

    // OC-5054 negative: an image item shows no trigger text, and its hotkey is still editable and saved.
    @Test func imageItemHasNoTriggerButSavesAHotkeyClear() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, kind: .image, hotkey: cmdK)
        let model = await rig.loaded(1)
        #expect(model.triggerOffered == false)
        #expect(model.triggerText == "")
        #expect(model.hotkey == cmdK)
        model.triggerText = ";typed"  // a stray write must not become a stored trigger on a non-text item
        #expect(model.triggerErrorMessage == nil)

        model.clearHotkey()
        await model.save()

        #expect(model.phase == .saved)
        let stored = try await rig.stored()
        #expect(stored.hotkeys == [:])
        #expect(stored.triggers == [:])
        #expect(rig.didSave.value == 0)
    }
}

// MARK: Load

@MainActor
@Suite struct WorfEditorLoadTests {
    @Test func loadShowsTheStoredTriggerAndHotkey() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, trigger: ";sig", hotkey: cmdK)
        let model = await rig.loaded(1)
        #expect(model.phase == .ready)
        #expect(model.triggerText == ";sig")
        #expect(model.hotkey == cmdK)
        #expect(model.canSave)
    }

    @Test func beforeLoadNothingCanBeSaved() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = rig.model(1)
        model.triggerText = ";early"
        #expect(model.phase == .loading)
        #expect(model.canSave == false)
        await model.save()
        #expect(model.phase == .loading)
        #expect(try await rig.stored() == ItemBindings())
    }

    // The item is not in the database at all: the editor reports and shows failure, and writes nothing.
    @Test func missingItemFailsToLoadAndReportsOnce() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(99)
        #expect(model.phase == .failed)
        #expect(rig.reports.value.map(\.code) == [.libIo001])
        #expect(model.canSave == false)
        #expect(try await rig.rowCount() == 1)
    }
}

// MARK: Save through applyExemptionEdit (OC-5056, OC-5057, OC-5061)

@MainActor
@Suite struct WorfEditorSaveTests {
    // OC-5057: change ;a to ;b leaves exactly one trigger on the item, and the first-save hook runs once.
    @Test func changingATriggerLeavesOnlyTheNewOne() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, trigger: ";a")
        try await rig.seed(2)
        let model = await rig.loaded(1)
        model.triggerText = ";b"
        await model.save()

        #expect(model.phase == .saved)
        let stored = try await rig.stored()
        #expect(stored.triggers == [uid(1): ";b"])
        #expect(stored.hotkeys == [:])
        #expect(try await rig.rowCount() == 2)
        #expect(rig.didSave.value == 1)
    }

    @Test func assigningAFreshTriggerAndHotkeyStoresBothAndPromptsOnce() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        try await rig.seed(2, trigger: ";other", hotkey: cmdJ)
        let model = await rig.loaded(1)
        model.triggerText = ";new"
        await model.save()

        let stored = try await rig.stored()
        #expect(stored.triggers == [uid(1): ";new", uid(2): ";other"])
        #expect(stored.hotkeys == [uid(2): cmdJ])
        #expect(rig.didSave.value == 1)
    }

    // OC-5056: clearing the field removes the trigger; clearing is not a "saved a trigger" so no permission prompt.
    @Test func clearingTheTriggerRemovesItAndDoesNotPrompt() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, trigger: ";gone")
        try await rig.seed(2, trigger: ";stay")
        let model = await rig.loaded(1)
        model.triggerText = ""
        await model.save()

        #expect(model.phase == .saved)
        #expect(try await rig.stored().triggers == [uid(2): ";stay"])
        #expect(rig.didSave.value == 0)
    }

    // OC-5061: clear hotkey removes it and leaves the trigger alone; hotkey-only edit never prompts.
    @Test func clearingTheHotkeyKeepsTheTriggerAndDoesNotPrompt() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, trigger: ";keep", hotkey: cmdK)
        let model = await rig.loaded(1)
        model.clearHotkey()
        #expect(model.hotkey == nil)
        await model.save()

        let stored = try await rig.stored()
        #expect(stored.hotkeys == [:])
        #expect(stored.triggers == [uid(1): ";keep"])
        #expect(rig.didSave.value == 0)
    }

    // Boundary: saving with nothing changed writes nothing, prompts nothing, and still completes.
    @Test func saveWithNoChangeWritesNothing() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, trigger: ";same", hotkey: cmdK)
        let model = await rig.loaded(1)
        await model.save()

        #expect(model.phase == .saved)
        let stored = try await rig.stored()
        #expect(stored.triggers == [uid(1): ";same"])
        #expect(stored.hotkeys == [uid(1): cmdK])
        #expect(rig.didSave.value == 0)
        #expect(rig.huds.value.isEmpty)
    }

    // Boundary of the grammar: 2 and 24 bytes save, 1 and 25 do not.
    @Test func triggerLengthBoundaries() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(1)
        let cases: [(String, Bool)] = [(";", false), (";a", true), (";" + String(repeating: "a", count: 23), true), (";" + String(repeating: "a", count: 24), false)]
        for (text, valid) in cases {
            model.triggerText = text
            #expect((model.triggerErrorMessage == nil) == valid, "trigger of \(text.utf8.count) bytes")
            #expect(model.canSave == valid)
        }
    }

    // The item is deleted (a sweep) after the editor opened: save reports `.gone`, writes nothing, does not prompt.
    @Test func savingAnItemDeletedUnderTheEditorEndsAsGone() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        try await rig.seed(2)
        let model = await rig.loaded(1)
        try await rig.database.pool.write { try $0.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [uid(1).uuidString]) }
        model.triggerText = ";late"
        await model.save()

        #expect(model.phase == .gone)
        #expect(try await rig.rowCount() == 1)
        #expect(try await rig.stored() == ItemBindings())
        #expect(rig.didSave.value == 0)
        #expect(rig.reports.value.isEmpty)
    }

    // The unique index is the backstop when another item took the trigger after the editor loaded (stale snapshot).
    @Test func triggerTakenAfterLoadIsRefusedByTheDatabaseAndReported() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        try await rig.seed(2)
        let model = await rig.loaded(1)
        _ = try await rig.database.applyExemptionEdit(.setTrigger(";race"), to: uid(2)).get()
        model.triggerText = ";RACE"
        #expect(model.triggerErrorMessage == nil)  // the editor's snapshot is stale: it cannot know
        await model.save()

        #expect(model.phase == .ready)
        #expect(rig.reports.value.count == 1)
        #expect(try await rig.stored().triggers == [uid(2): ";race"])
        #expect(rig.didSave.value == 0)
    }
}

// MARK: Trigger validation (OC-5059, FR-005-08)

@MainActor
@Suite struct WorfEditorValidationTests {
    // OC-5059: "x" blocks saving with the inline TRG-VAL-001 text; nothing is written.
    @Test func invalidTriggerShowsTheInlineErrorAndBlocksSave() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(1)
        model.triggerText = "x"

        #expect(model.triggerErrorMessage == msgInvalid)
        #expect(model.canSave == false)
        await model.save()
        #expect(model.phase == .ready)
        #expect(try await rig.stored() == ItemBindings())
        #expect(rig.didSave.value == 0)

        model.triggerText = ";x"  // fixing the text lifts the block
        #expect(model.triggerErrorMessage == nil)
        #expect(model.canSave)
    }

    @Test func triggerWithASpaceIsRejected() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(1)
        model.triggerText = ";a b"
        #expect(model.triggerErrorMessage == msgInvalid)
        #expect(model.canSave == false)
    }

    // FR-005-08 uniqueness is case-insensitive and across items; the item's own trigger may be saved unchanged.
    @Test func duplicateTriggerIsRejectedCaseInsensitivelyButOwnTriggerIsAllowed() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, trigger: ";mine")
        try await rig.seed(2, trigger: ";Sig")
        let model = await rig.loaded(1)

        #expect(model.triggerErrorMessage == nil)  // own trigger unchanged
        model.triggerText = ";sig"
        #expect(model.triggerErrorMessage == msgDuplicate)
        #expect(model.canSave == false)
        await model.save()
        #expect(model.phase == .ready)
        #expect(try await rig.stored().triggers == [uid(1): ";mine", uid(2): ";Sig"])

        model.triggerText = ";sigs"  // near miss is fine
        #expect(model.triggerErrorMessage == nil)
    }

    // OC-5058: an unknown template variable warns on save and never blocks it. The warning's TEXT is the defect test below.
    @Test func unknownVariableSavesAndWarnsOnce() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, text: "Dear {nosuchvariable}")
        let model = await rig.loaded(1)
        #expect(model.warningMessage == nil)  // nothing would paste it yet
        model.triggerText = ";warn"
        #expect(model.warningMessage != nil)
        #expect(model.canSave)
        await model.save()

        #expect(model.phase == .saved)
        #expect(try await rig.stored().triggers == [uid(1): ";warn"])
        #expect(rig.huds.value.count == 1)
        #expect(rig.didSave.value == 1)
    }

    // OC-5058 `then`: the warning reads 'An unknown variable was left as plain text.' (TASK-395: validate used to attach
    // a `count` context the catalogue template has no placeholder for, so the text fell back to SYS-INT-001.)
    @Test func unknownVariableWarningReadsTheCatalogueText() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, text: "Hi {foo}")
        let model = await rig.loaded(1)
        model.triggerText = ";foo1"
        await model.save()

        #expect(model.warningMessage == msgUnknownVariable)
        #expect(rig.huds.value == [msgUnknownVariable])
    }

    // Negative of OC-5058: ordinary text and a known variable raise no warning and no HUD.
    @Test func knownVariablesRaiseNoWarning() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, text: "Hi {clipboard} on {date}")
        let model = await rig.loaded(1)
        model.triggerText = ";fine"
        #expect(model.warningMessage == nil)
        await model.save()
        #expect(model.phase == .saved)
        #expect(rig.huds.value.isEmpty)
    }
}

// MARK: Hotkey recorder reuse and conflicts (FR-005-04, FR-005-09)

// Serialized: a recorder's local monitor sees every key-down in the process, so two recording tests must not overlap.
@MainActor
@Suite(.serialized) struct WorfEditorRecorderTests {
    // Recording blocks saving (canSave) and parks the registry's global hotkeys; stop lifts both.
    @Test func recordingBlocksSaveUntilItStops() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(1)
        model.triggerText = ";rec"
        #expect(model.canSave)

        model.startRecording()
        #expect(model.recorder.isRecording)
        #expect(model.canSave == false)
        await model.save()
        #expect(model.phase == .ready)
        #expect(try await rig.stored() == ItemBindings())

        model.stopRecording()
        #expect(model.recorder.isRecording == false)
        #expect(model.canSave)
    }

    // A recorded chord goes through the same validator Settings uses, lands in the editor, and is saved on Save only.
    @Test func recordedChordIsHeldUntilSaveThenStored() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, trigger: ";keep")
        let model = await rig.loaded(1)
        model.startRecording()
        pressInProcess(keyCode: 40, modifiers: [.command])  // ⌘K

        #expect(model.hotkey == cmdK)
        #expect(model.recorder.isRecording == false)
        #expect(try await rig.stored().hotkeys == [:])  // not written before Save

        await model.save()
        let stored = try await rig.stored()
        #expect(stored.hotkeys == [uid(1): cmdK])
        #expect(stored.triggers == [uid(1): ";keep"])
        #expect(rig.didSave.value == 0)  // hotkey-only save: trigger unchanged, no permission prompt
    }

    // The recorder refuses a chord with no ⌘/⌃ inline (TRG-VAL-003), keeps recording, and changes nothing.
    @Test func recorderRejectsAnInvalidChordAndKeepsRecording() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(1)
        model.startRecording()
        pressInProcess(keyCode: 40, modifiers: [.shift])  // ⇧K: no ⌘ or ⌃

        #expect(model.hotkey == nil)
        #expect(model.recorder.isRecording)
        #expect(model.recorder.errorMessage == "Shortcuts need ⌘ or ⌃ plus a key, and can't be a reserved system shortcut.")
        model.stopRecording()
    }

    // FR-005-04 / AC-005-04 (TASK-403): a rejected chord's inline error does not outlive the accepted chord that follows.
    @Test func acceptedChordClearsThePriorInlineError() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(1)
        model.startRecording()
        pressInProcess(keyCode: 8, modifiers: [.command])  // ⌘C: reserved, rejected
        #expect(model.recorder.errorMessage != nil)
        #expect(model.recorder.isRecording)

        pressInProcess(keyCode: 11, modifiers: [.control, .option])  // ⌃⌥B: accepted
        #expect(model.hotkey == Chord(keyCode: 11, modifiers: [.control, .option]))
        #expect(model.recorder.isRecording == false)
        #expect(model.recorder.errorMessage == nil)
    }

    // FR-005-04: Esc after a rejected chord also leaves no stale error.
    @Test func escapeClearsThePriorInlineError() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(1)
        model.startRecording()
        pressInProcess(keyCode: 8, modifiers: [.command])  // ⌘C: rejected
        #expect(model.recorder.errorMessage != nil)

        pressInProcess(keyCode: 53, modifiers: [])  // Esc
        #expect(model.recorder.isRecording == false)
        #expect(model.recorder.errorMessage == nil)
    }

    // A chord another Flotsam binding already owns is refused by the recorder (TRG-VAL-004).
    @Test func recorderRefusesAChordAnotherBindingOwns() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        rig.registry.bind(.openLibrary, to: cmdL)
        let model = await rig.loaded(1)
        model.startRecording()
        pressInProcess(keyCode: 37, modifiers: [.command])  // ⌘L, taken

        #expect(model.hotkey == nil)
        #expect(model.recorder.isRecording)
        #expect(model.recorder.errorMessage == msgChordTaken)
        model.stopRecording()
    }

    // Esc cancels, Delete clears (clear is allowed for an item hotkey, FR-005-01).
    @Test func escapeCancelsAndDeleteClearsTheHotkey() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, hotkey: cmdK)
        let model = await rig.loaded(1)

        model.startRecording()
        pressInProcess(keyCode: 53, modifiers: [])  // Esc
        #expect(model.recorder.isRecording == false)
        #expect(model.hotkey == cmdK)

        model.startRecording()
        pressInProcess(keyCode: 51, modifiers: [])  // Delete
        #expect(model.recorder.isRecording == false)
        #expect(model.hotkey == nil)
    }

    // Another binding takes the chord between recording and Save: the editor stays open, the hotkey reverts, a HUD
    // says why, and nothing is written (including the trigger).
    @Test func chordTakenWhileTheEditorIsOpenKeepsItOpenAndWritesNothing() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(1)
        model.startRecording()
        pressInProcess(keyCode: 38, modifiers: [.command])  // ⌘J accepted at record time
        #expect(model.hotkey == cmdJ)
        model.triggerText = ";both"
        rig.registry.bind(.toggleShelf, to: cmdJ)  // a Settings change lands before Save

        await model.save()

        #expect(model.phase == .ready)
        #expect(model.hotkey == nil)
        #expect(rig.huds.value == [msgChordTaken])
        #expect(try await rig.stored() == ItemBindings())
        #expect(rig.didSave.value == 0)
    }
}

// MARK: Worf, TASK-403 (FR-005-04, AC-005-04), blind: the recorder's inline error follows recording, never outlives it

private struct StubSystemChords: SystemHotkeyProvider {
    let chords: Set<Chord>
    func enabledSystemChords() -> Set<Chord> { chords }
}

private let msgChordInvalid = "Shortcuts need ⌘ or ⌃ plus a key, and can't be a reserved system shortcut."

extension WorfEditorRecorderTests {
    // AC-005-04. Red if the error is cleared when a rejection lands while one is already showing (reject, reject, reject).
    @Test func consecutiveRejectedChordsEachKeepTheErrorAndKeepRecording() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(1)
        model.startRecording()

        pressInProcess(keyCode: 8, modifiers: [.command])  // ⌘C
        #expect(model.recorder.errorMessage == msgChordInvalid)
        pressInProcess(keyCode: 12, modifiers: [.command])  // ⌘Q
        #expect(model.recorder.errorMessage == msgChordInvalid)
        #expect(model.recorder.isRecording)
        pressInProcess(keyCode: 0, modifiers: [.option])  // ⌥A
        #expect(model.recorder.errorMessage == msgChordInvalid)
        #expect(model.recorder.isRecording)
        #expect(model.hotkey == nil)
        model.stopRecording()
    }

    // FR-005-02 / FR-005-04. Red if a later rejection leaves the earlier code's message (stale 003 after a 004) in place.
    @Test func eachRejectionShowsItsOwnMessageNotThePreviousOne() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        rig.registry.bind(.openLibrary, to: cmdL)
        let model = await rig.loaded(1)
        model.startRecording()

        pressInProcess(keyCode: 8, modifiers: [.command])  // ⌘C reserved
        #expect(model.recorder.errorMessage == msgChordInvalid)
        pressInProcess(keyCode: 37, modifiers: [.command])  // ⌘L taken
        #expect(model.recorder.errorMessage == msgChordTaken)
        pressInProcess(keyCode: 8, modifiers: [.command])  // ⌘C again
        #expect(model.recorder.errorMessage == msgChordInvalid)
        #expect(model.recorder.isRecording)
        model.stopRecording()
    }

    // FR-005-04: Delete (clear allowed) ends recording, so it leaves no error beside the cleared binding.
    @Test func deleteAfterARejectedChordClearsTheErrorAndTheBinding() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, hotkey: cmdK)
        let model = await rig.loaded(1)
        model.startRecording()
        pressInProcess(keyCode: 8, modifiers: [.command])  // ⌘C rejected
        #expect(model.recorder.errorMessage == msgChordInvalid)

        pressInProcess(keyCode: 51, modifiers: [])  // Delete
        #expect(model.recorder.isRecording == false)
        #expect(model.recorder.errorMessage == nil)
        #expect(model.hotkey == nil)
    }

    // FR-005-04: focus loss and the view going away end recording through stop(); no error may remain, and a new
    // session starts clean and can accept a chord.
    @Test func focusLossAfterARejectedChordClearsTheErrorAndANewSessionStartsClean() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(1)
        model.startRecording()
        pressInProcess(keyCode: 8, modifiers: [.command])  // ⌘C rejected
        #expect(model.recorder.errorMessage == msgChordInvalid)

        model.stopRecording()  // what didResignKey, onDisappear and windowWillClose all call
        #expect(model.recorder.isRecording == false)
        #expect(model.recorder.errorMessage == nil)

        model.startRecording()
        #expect(model.recorder.isRecording)
        #expect(model.recorder.errorMessage == nil)
        pressInProcess(keyCode: 11, modifiers: [.control, .option])  // ⌃⌥B
        #expect(model.hotkey == Chord(keyCode: 11, modifiers: [.control, .option]))
        #expect(model.recorder.errorMessage == nil)
    }

    // FR-005-04: stop() with nothing recording is a no-op and leaves no error.
    @Test func stopWhenNotRecordingLeavesNoError() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1)
        let model = await rig.loaded(1)
        model.stopRecording()
        #expect(model.recorder.isRecording == false)
        #expect(model.recorder.errorMessage == nil)
    }

    // FR-005-02 (a)-(d) through the recorder: every reserved chord, every missing-modifier shape and a macOS-owned chord
    // is rejected with the TRG-VAL-003 message and keeps recording; ⌘⇧C (not reserved) is accepted. Fresh session per chord.
    @Test func everyRejectionPathShowsItsMessageAndAcceptedNeighboursClear() async throws {
        let osChord = Chord(keyCode: 20, modifiers: [.control, .shift])  // stand-in for an enabled symbolic hotkey
        let registry = ShortcutRegistry(registrar: StubRegistrar(), systemHotkeys: StubSystemChords(chords: [osChord]))
        let recorder = ShortcutRecorderModel()
        let committed = Box<[ChordBinding]>([])
        let id = ShortcutID.toggleShelf
        let rejected: [(UInt16, NSEvent.ModifierFlags)] = [
            (12, [.command]), (13, [.command]), (4, [.command]), (46, [.command]), (48, [.command]), (49, [.command]),
            (49, [.control]), (53, [.command, .option]), (43, [.command]),
            (8, [.command]), (9, [.command]), (7, [.command]), (6, [.command]), (0, [.command]),
            (0, [.option]), (0, [.option, .shift]), (0, [.shift]), (0, []),  // rule (a): no ⌘ or ⌃
            (20, [.control, .shift]),  // rule (d)
        ]
        for (code, flags) in rejected {
            recorder.start(registry: registry, id: id, allowClear: true) { committed.value.append($0) }
            #expect(recorder.errorMessage == nil, "key \(code) \(flags.rawValue): clean at start")
            pressInProcess(keyCode: code, modifiers: flags)
            #expect(recorder.errorMessage == msgChordInvalid, "key \(code) \(flags.rawValue)")
            #expect(recorder.isRecording, "key \(code) \(flags.rawValue)")
            recorder.stop()
            #expect(recorder.errorMessage == nil, "key \(code) \(flags.rawValue): cleared by stop")
        }
        #expect(committed.value.isEmpty)

        let accepted: [(UInt16, NSEvent.ModifierFlags)] = [(8, [.command, .shift]), (11, [.control, .option]), (25, [.command, .shift])]
        for (code, flags) in accepted {
            recorder.start(registry: registry, id: id, allowClear: true) { committed.value.append($0) }
            pressInProcess(keyCode: 12, modifiers: [.command])  // a reject first, so a stale error would show
            pressInProcess(keyCode: code, modifiers: flags)
            #expect(recorder.isRecording == false, "key \(code)")
            #expect(recorder.errorMessage == nil, "key \(code)")
        }
        #expect(committed.value == [
            .chord(Chord(keyCode: 8, modifiers: [.command, .shift])),
            .chord(Chord(keyCode: 11, modifiers: [.control, .option])),
            .chord(Chord(keyCode: 25, modifiers: [.command, .shift])),
        ])
    }

    // FR-005-01 / FR-005-04: where clearing is not allowed (openLibrary), Delete does nothing and recording continues; Esc then
    // ends it with no error left. Red if Delete committed or stopped the recorder.
    @Test func deleteWhereClearingIsRefusedKeepsRecordingAndEscEndsCleanly() async throws {
        let registry = ShortcutRegistry(registrar: StubRegistrar())
        let recorder = ShortcutRecorderModel()
        let committed = Box<[ChordBinding]>([])
        recorder.start(registry: registry, id: .openLibrary, allowClear: false) { committed.value.append($0) }
        pressInProcess(keyCode: 8, modifiers: [.command])  // ⌘C rejected
        #expect(recorder.errorMessage == msgChordInvalid)

        pressInProcess(keyCode: 51, modifiers: [])  // Delete, refused
        #expect(recorder.isRecording)
        #expect(committed.value.isEmpty)

        pressInProcess(keyCode: 53, modifiers: [])  // Esc
        #expect(recorder.isRecording == false)
        #expect(recorder.errorMessage == nil)
        #expect(committed.value.isEmpty)
    }
}
