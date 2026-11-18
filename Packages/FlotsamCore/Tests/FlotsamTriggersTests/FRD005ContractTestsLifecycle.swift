import FlotsamBase
import FlotsamPaste
import Foundation
import GRDB
import Testing
@testable import FlotsamStorage
@testable import FlotsamTriggers

// FRD-005 8T slice S9 (Lifecycle), the engine and expander halves: a real GRDB database is the engine's binding source,
// its event bus and the expander's content store, so deletes and edits reach the trigger snapshot the way the app wires
// them. Only the OS edge is a double (event tap, pasteboard, key poster, frontmost app). Expected values are literals.
//
// UNTESTABLE-AT-PACKAGE (named seam): the contract's "in TextEdit" half, that the characters really stay in a real
// TextEdit document and that a real text field receives the paste, needs a live CGEventTap and the real pasteboard.
// There is no harness for either in the package. This file asserts the decision the tap makes (`.pass` vs `.consume`),
// and what the expander would write to the pasteboard and post.

private struct NoPanel: PasteHost {
    var isPanelVisible: Bool { false }
    func hidePanel() {}
}

@MainActor
private final class LifecycleRig {
    let root: URL
    let database: FlotsamDatabase
    let pasteboard = ExpansionPasteboard(plainText: "previous clipboard")
    let keys = RecordingKeys()
    let environment = FakeKeyboardEnvironment()
    let permissions = FakePermissions()
    let snapshot = TriggerSnapshotStore()
    let presenter = RecordingPresenter()
    let sink = RecordingSink()
    let source = FakeKeyEventSource()
    let settings = SettingsStore(store: InMemoryKeyValueStore())
    let paste: PasteService
    let engine: TriggerEngine

    static func make() async throws -> LifecycleRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-frd005-s9-\(UUID().uuidString)")
        return LifecycleRig(root: root, database: try await FlotsamDatabase.open(folder: root).get())
    }

    private init(root: URL, database: FlotsamDatabase) {
        self.root = root
        self.database = database
        let clock = ManualClock()
        let reporter = ErrorReporter(presenter: presenter, clock: clock, sink: sink)
        let ledger = OwnWriteLedger()
        let preserver = ClipboardPreserver(pasteboard: pasteboard, ownWrites: ledger, clock: clock)
        paste = PasteService(
            store: database, pasteboard: pasteboard, files: NoFiles(), frontmost: EnvironmentFrontmost(environment: environment),
            accessibility: permissions, keys: keys, clock: clock, ownWrites: ledger)
        let expander = TriggerExpander(
            store: database, pasteboard: pasteboard, files: NoFiles(), codec: NoRichText(), preserver: preserver,
            ownWrites: ledger, paste: paste, keys: keys, keyboard: environment, snapshot: snapshot,
            permissions: permissions, reporter: reporter, clock: clock, ownBundleId: "com.example.flotsam",
            calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"), sink: sink)
        environment.frontmost = ExpanderHarness.app
        keys.frontmost = { [environment] in environment.frontmost }
        settings.set(true, for: SettingKeys.triggersEnabled)
        engine = TriggerEngine(
            source: source, snapshot: snapshot, bindings: database, settings: settings, bus: database.events,
            expander: expander, keyboard: environment, permissions: permissions, reporter: reporter, clock: GatedClock(),
            resetSignal: TriggerResetSignal(), ownBundleId: "com.example.flotsam", pollTick: PollTick())
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func seed(_ n: Int, text: String, trigger: String?) async throws {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
        let now = Int64(Date().timeIntervalSince1970 * 1000) - Int64(n)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize,
                                      pinned, updatedAt)
                    VALUES (?, 'text', ?, ?, ?, ?, ?, 0, 0, ?)
                    """,
                arguments: [id.uuidString, now, now, "key-s9-\(n)", text, text, now])
        }
        if let trigger { _ = try await database.applyExemptionEdit(.setTrigger(trigger), to: id).get() }
    }

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    /// The user types `word` then Space; the decision for the Space.
    func typeAndSpace(_ word: String) -> KeyDecision {
        source.type(word)
        return source.press(TriggerKeys.space, " ")
    }

    /// Plain text of every item write the expander or paste service made, oldest first. The user's own clipboard text
    /// being put back after a paste is not an item write, so it is left out.
    var writtenTexts: [String] {
        pasteboard.writes.compactMap { write in
            write.first { $0.uti == "public.utf8-plain-text" }.flatMap { String(data: $0.data, encoding: .utf8) }
        }.filter { $0 != "previous clipboard" }
    }
}

@MainActor
@Suite("FRD-005 contract: lifecycle, engine halves (S9)", .serialized, .timeLimit(.minutes(2)))
struct FRD005ContractTestsLifecycleTriggers {
    // Red if the delete does not drop the trigger from the snapshot before it returns (the next ';del' Space would be
    // consumed and pasted), or if dropping it also drops the survivor's.
    @Test("OC-5133 after the item holding ';del' is deleted, ';del' Space is not consumed and nothing is pasted; the other trigger still expands")
    func oc5133_deletedTriggerStaysTyped() async throws {
        // given: item 1 ';del' = 'gone text' and item 2 ';keep' = 'kept text', the engine running over the real database
        let rig = try await LifecycleRig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, text: "gone text", trigger: ";del")
        try await rig.seed(2, text: "kept text", trigger: ";keep")
        await rig.engine.start()
        defer { rig.engine.stop() }
        #expect(rig.engine.status != .idle)
        // control: before the delete ';del' Space is consumed and pastes 'gone text'
        #expect(rig.typeAndSpace(";del") == .consume)
        #expect(await eventually { rig.writtenTexts.contains("gone text") })
        let writesBefore = rig.pasteboard.writes.count
        let postedBefore = rig.keys.actions.count
        // when: the user deletes the item and types ';del' Space again without relaunching
        let deleted = try await rig.database.delete(ids: [LifecycleRig.id(1)]).get()
        let decision = rig.typeAndSpace(";del")
        // then: the Space passes through (';del ' stays as typed), no write, no key posted
        #expect(deleted == [LifecycleRig.id(1)])
        #expect(decision == .pass)
        #expect(rig.pasteboard.writes.count == writesBefore)
        #expect(rig.keys.actions.count == postedBefore)
        // and the survivor's trigger still expands its own text
        #expect(rig.typeAndSpace(";keep") == .consume)
        #expect(await eventually { rig.writtenTexts.contains("kept text") })
        #expect(rig.snapshot.policy.triggers.count == 1)
    }

    // Red if the expander reads a cached copy of the text instead of the item as stored now, or if the edit loses the
    // trigger.
    @Test("OC-5138 after editing the text from 'one' to 'two', ';e' Space and the item hotkey path both write 'two'")
    func oc5138_editedTextIsWhatInserts() async throws {
        // given: ';e' bound to an item whose text is 'one', the engine running
        let rig = try await LifecycleRig.make()
        defer { rig.cleanUp() }
        try await rig.seed(1, text: "one", trigger: ";e")
        await rig.engine.start()
        defer { rig.engine.stop() }
        #expect(rig.typeAndSpace(";e") == .consume)
        #expect(await eventually { rig.writtenTexts == ["one"] })
        // when: the user edits the text to 'two', then expands ';e' and fires the item hotkey (the paste sequence a chord runs)
        let classifiers = ItemClassifiers(
            editedText: { ItemClassification(kind: .text, contentKey: "edit:" + $0) },
            fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) })
        _ = try await rig.database.editText(id: LifecycleRig.id(1), to: "two", classifiers: classifiers).get()
        #expect(rig.typeAndSpace(";e") == .consume)
        #expect(await eventually { rig.writtenTexts.count == 2 })
        let outcome = try await rig.paste.paste(
            itemId: LifecycleRig.id(1), mode: .paste, target: ExpanderHarness.app, host: NoPanel()).get()
        // then: the trigger wrote 'two' (not 'one'), and so did the hotkey path
        #expect(rig.writtenTexts[1] == "two")
        #expect(rig.writtenTexts.count == 3)
        #expect(rig.writtenTexts[2] == "two")
        #expect(rig.writtenTexts.filter { $0 == "one" }.count == 1)
        _ = outcome
    }

    // Red if Flotsam's own bundle is only excluded when it happens to be in the stored list, or if the policy excludes
    // an ordinary app.
    @Test("OC-5094 Flotsam's own windows are always excluded even with an empty list; an ordinary app is not; a listed app is")
    func oc5094_ownBundleAlwaysExcluded() {
        // given: an empty excluded list, and one with Terminal
        let empty = TriggerPolicy(excludedApps: [])
        let withTerminal = TriggerPolicy(excludedApps: ["com.apple.Terminal"])
        // when / then
        #expect(empty.excludes(bundleId: "com.example.flotsam", ownBundleId: "com.example.flotsam"))
        #expect(!empty.excludes(bundleId: "com.apple.TextEdit", ownBundleId: "com.example.flotsam"))
        #expect(!empty.excludes(bundleId: "com.apple.Terminal", ownBundleId: "com.example.flotsam"))
        #expect(withTerminal.excludes(bundleId: "com.apple.Terminal", ownBundleId: "com.example.flotsam"))
        #expect(!withTerminal.excludes(bundleId: "com.apple.TextEdit", ownBundleId: "com.example.flotsam"))
    }
}
