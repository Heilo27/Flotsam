import AppKit
import FlotsamBase
import FlotsamShortcuts
import FlotsamStorage
import Foundation
import GRDB
import Testing
@testable import FlotsamStorage

// FRD-005 8T slice S9 (lifecycle), editor half of OC-5134 (FR-005-22): once the item holding a trigger and a hotkey is
// deleted and the registry has dropped its hotkey, the same trigger and chord are accepted for another item with no
// TRG-VAL-002 or TRG-VAL-004. The storage half (fresh bindings read, rebind through applyExemptionEdit) is in
// FlotsamStorageTests/FRD005ContractTestsLifecycle. Real editor model, real ShortcutRegistry, real GRDB database;
// what is stored is read through a FRESH database instance (B4). Expected strings and chords are literals.
// The registry rebuild on `itemsDeleted` is wired in the app container (OS half); each test emulates it with the
// registry's own `syncItemHotkeys`, the call the container makes.

private final class L9Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
private final class L9Registrar: HotkeyRegistrar {
    private var next: UInt32 = 1
    func register(_ chord: Chord, handler: @escaping @MainActor () -> Void) -> FlotsamResult<HotkeyRegistration> {
        defer { next += 1 }
        return .success(HotkeyRegistration(rawValue: next))
    }
    func unregister(_ registration: HotkeyRegistration) {}
    func unregisterAll() {}
}

private let l9CtrlOpt1 = Chord(keyCode: 18, modifiers: [.control, .option])
private let l9MsgDuplicate = "That trigger is already used by another item."
private let l9MsgChordTaken = "That shortcut is already used in Flotsam."

private func l9Id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

@MainActor
private final class L9Rig {
    let database: FlotsamDatabase
    let registry = ShortcutRegistry(registrar: L9Registrar())
    let reports = L9Box<[FlotsamError]>([])
    private let root: URL

    static func make() async throws -> L9Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-frd005-l9-\(UUID().uuidString)")
        return L9Rig(database: try await FlotsamDatabase.open(folder: root).get(), root: root)
    }

    private init(database: FlotsamDatabase, root: URL) {
        self.database = database
        self.root = root
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Inserts item `n` (text) with an optional stored trigger and hotkey.
    func seed(_ n: Int, trigger: String? = nil, hotkey: Chord? = nil) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize,
                                      pinned, updatedAt, hotkeyCode, hotkeyModifiers, "trigger")
                    VALUES (?, 'text', ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?)
                    """,
                arguments: [
                    l9Id(n).uuidString, now, now, "key-l9-\(n)", "item \(n)", "item \(n)", now,
                    hotkey.map { Int($0.keyCode) }, hotkey.map { Int($0.modifiers.rawValue) }, trigger,
                ])
        }
    }

    func editor(_ n: Int) async -> ItemBindingsEditorModel {
        let reports = reports
        let model = ItemBindingsEditorModel(
            itemId: l9Id(n),
            services: ItemBindingsEditorServices(
                database: database, registry: registry, didSaveTrigger: {},
                report: { reports.value.append($0) }, hud: { _ in }))
        await model.load()
        return model
    }

    /// What the registry would hold after the container's rebuild: exactly the hotkeys now in storage.
    func syncRegistryFromStorage() async throws {
        let bindings = try await database.itemBindings().get()
        registry.syncItemHotkeys(bindings.hotkeys) { _ in {} }
    }

    func stored() async throws -> ItemBindings {
        let fresh = try await FlotsamDatabase.open(folder: root).get()
        return try await fresh.itemBindings().get()
    }

    func presentIds() async throws -> Set<UUID> {
        let ids = try await database.pool.read { try String.fetchAll($0, sql: "SELECT id FROM item") }
        return Set(ids.compactMap(UUID.init(uuidString:)))
    }
}

/// One key-down through `NSApplication.sendEvent`, which runs the recorder's local monitor. In-process only.
@MainActor
private func l9Press(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
    _ = NSApplication.shared
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: keyCode)
    if let event { NSApplication.shared.sendEvent(event) }
}

// Nested under WorfEditorRecorderTests (a .serialized suite) on purpose: a recorder's local NSEvent monitor sees every
// key-down in the process and the earliest-registered live one consumes it, so these recording tests must not interleave
// with that suite's. Run in parallel they failed 2 runs in 3 (the press reached another test's recorder).
extension WorfEditorRecorderTests {
@MainActor
@Suite struct FRD005ContractTestsLifecycleEditor {
    // Red if the editor or the registry keep rejecting ';del' or the chord after the holder was deleted and the registry
    // rebuilt (stale snapshot of other triggers or stale registry binding), or if they accept them while the holder lives.
    @Test("OC-5134 holder of ';del' and ⌃⌥1 deleted: another item's editor then accepts both with no TRG-VAL-002 or TRG-VAL-004, and saves them")
    func oc5134_editorAcceptsAfterDelete() async throws {
        // given: item 1 holds ';del' and ⌃⌥1 (registered); item 2 holds nothing
        let rig = try await L9Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, trigger: ";del", hotkey: l9CtrlOpt1)
        try await rig.seed(2)
        try await rig.syncRegistryFromStorage()
        // while the holder lives, both are refused in item 2's editor (so a later acceptance is a real change)
        let before = await rig.editor(2)
        before.triggerText = ";del"
        #expect(before.triggerErrorMessage == l9MsgDuplicate)
        #expect(before.canSave == false)
        before.startRecording()
        l9Press(keyCode: 18, modifiers: [.control, .option])
        #expect(before.recorder.errorMessage == l9MsgChordTaken)
        #expect(before.hotkey == nil)
        before.stopRecording()
        // when: item 1 is deleted, the registry rebuilds, and a freshly opened editor for item 2 takes both
        let deleted = try await rig.database.delete(ids: [l9Id(1)]).get()
        try await rig.syncRegistryFromStorage()
        let after = await rig.editor(2)
        after.triggerText = ";del"
        after.startRecording()
        l9Press(keyCode: 18, modifiers: [.control, .option])
        // then: no inline error, the recorder committed the chord, the save goes through and a fresh read shows item 2 alone
        #expect(deleted == [l9Id(1)])
        #expect(after.triggerErrorMessage == nil)
        #expect(after.recorder.errorMessage == nil)
        #expect(after.hotkey == l9CtrlOpt1)
        #expect(after.canSave)
        await after.save()
        #expect(after.phase == .saved)
        #expect(rig.reports.value.isEmpty)
        let stored = try await rig.stored()
        #expect(stored.triggers == [l9Id(2): ";del"])
        #expect(stored.hotkeys == [l9Id(2): l9CtrlOpt1])
        #expect(try await rig.presentIds() == [l9Id(2)])
    }

    // Red if deleting an unrelated item frees the holder's trigger or chord (the rejection must follow the holder, not any delete).
    @Test("OC-5134 negative: deleting a different item leaves ';del' and ⌃⌥1 taken; the editor still rejects both")
    func oc5134_unrelatedDeleteFreesNothing() async throws {
        // given: item 1 holds ';del' and ⌃⌥1; items 2 and 3 hold nothing
        let rig = try await L9Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, trigger: ";del", hotkey: l9CtrlOpt1)
        try await rig.seed(2)
        try await rig.seed(3)
        try await rig.syncRegistryFromStorage()
        // when: item 3 is deleted and the registry rebuilds, then item 2's editor tries both
        _ = try await rig.database.delete(ids: [l9Id(3)]).get()
        try await rig.syncRegistryFromStorage()
        let editor = await rig.editor(2)
        editor.triggerText = ";DEL"
        editor.startRecording()
        l9Press(keyCode: 18, modifiers: [.control, .option])
        // then: both still refused (the trigger case-insensitively), holder intact in a fresh read, two items remain
        #expect(editor.triggerErrorMessage == l9MsgDuplicate)
        #expect(editor.canSave == false)
        #expect(editor.recorder.errorMessage == l9MsgChordTaken)
        #expect(editor.hotkey == nil)
        editor.stopRecording()
        let stored = try await rig.stored()
        #expect(stored.triggers == [l9Id(1): ";del"])
        #expect(stored.hotkeys == [l9Id(1): l9CtrlOpt1])
        #expect(try await rig.presentIds() == [l9Id(1), l9Id(2)])
    }
}
}
