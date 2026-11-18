import FlotsamBase
import FlotsamShortcuts
import FlotsamStorage
import Foundation
import GRDB
import Testing
@testable import FlotsamStorage

// Worf, TASK-395 (FR-005-09, FR-005-17, AC-005-16, OC-5058), blind. Drives the real editor model against a real GRDB
// database. Expected strings are literals. Persisted state is read back through a SECOND database instance (B4).
// Mutation that must turn these red: put a `count` context back on the TRG-VAL-005 error in TemplateVariables.validate.

private final class W395Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
private final class W395Registrar: HotkeyRegistrar {
    private var next: UInt32 = 1
    func register(_ chord: Chord, handler: @escaping @MainActor () -> Void) -> FlotsamResult<HotkeyRegistration> {
        defer { next += 1 }
        return .success(HotkeyRegistration(rawValue: next))
    }
    func unregister(_ registration: HotkeyRegistration) {}
    func unregisterAll() {}
}

private let w395Id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let w395Text = "An unknown variable was left as plain text."
private let w395Generic =
    "Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings \u{203A} About."

@MainActor
private final class W395Rig {
    let database: FlotsamDatabase
    let registry = ShortcutRegistry(registrar: W395Registrar())
    let huds = W395Box<[String]>([])
    let reports = W395Box<[FlotsamError]>([])

    static func make() async throws -> W395Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-worf395-\(UUID().uuidString)")
        return W395Rig(database: try await FlotsamDatabase.open(folder: root).get(), root: root)
    }

    private init(database: FlotsamDatabase, root: URL) {
        self.database = database
        self.root = root
    }
    private let root: URL
    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func seed(_ text: String) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize,
                                      pinned, updatedAt)
                    VALUES (?, 'text', ?, ?, 'key-1', ?, ?, 0, 0, ?)
                    """,
                arguments: [w395Id.uuidString, now, now, text, text, now])
        }
    }

    func loaded() async -> ItemBindingsEditorModel {
        let huds = huds, reports = reports
        let model = ItemBindingsEditorModel(
            itemId: w395Id,
            services: ItemBindingsEditorServices(
                database: database, registry: registry, didSaveTrigger: {},
                report: { reports.value.append($0) }, hud: { huds.value.append($0) }))
        await model.load()
        return model
    }

    func storedTriggers() async throws -> [UUID: String] {
        let fresh = try await FlotsamDatabase.open(folder: root).get()
        return try await fresh.itemBindings().get().triggers
    }
}

@MainActor
@Suite struct Worf395EditorWarningTests {
    // OC-5058 exact: 'Hi {foo}', trigger ';foo1' saves, inline warning is the catalogue sentence, one HUD with it.
    @Test func oneUnknownVariableShowsCatalogueTextAndSaves() async throws {
        let rig = try await W395Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed("Hi {foo}")
        let model = await rig.loaded()
        model.triggerText = ";foo1"
        #expect(model.warningMessage == "An unknown variable was left as plain text.")
        #expect(model.warningMessage != w395Generic)
        await model.save()
        #expect(model.phase == .saved)
        #expect(try await rig.storedTriggers() == [w395Id: ";foo1"])
        #expect(rig.huds.value == ["An unknown variable was left as plain text."])
        #expect(rig.reports.value.isEmpty)
    }

    // given several unknown variables, then still one HUD, one sentence, no count, never the generic text.
    @Test func severalUnknownVariablesShowOneCatalogueSentence() async throws {
        let rig = try await W395Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed("{a} {b} {date:@@} {clipboard:x}")
        let model = await rig.loaded()
        model.triggerText = ";many"
        #expect(model.warningMessage == "An unknown variable was left as plain text.")
        await model.save()
        #expect(rig.huds.value.count == 1)
        #expect(rig.huds.value == ["An unknown variable was left as plain text."])
        #expect(try await rig.storedTriggers() == [w395Id: ";many"])
    }

    // given known + unknown mixed, then the warning shows the catalogue text.
    @Test func mixedKnownAndUnknownShowsCatalogueText() async throws {
        let rig = try await W395Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed("{date} {foo} {clipboard} {{time}}")
        let model = await rig.loaded()
        model.triggerText = ";mix"
        #expect(model.warningMessage == "An unknown variable was left as plain text.")
        await model.save()
        #expect(rig.huds.value == ["An unknown variable was left as plain text."])
    }

    // given only known variables (and escaped / foreign braces), then no warning and no HUD; save still succeeds.
    @Test func noUnknownVariablesShowNoWarning() async throws {
        let rig = try await W395Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed("{date} {time:HH:mm} {clipboard} {{date}} {{ .Name }}")
        let model = await rig.loaded()
        model.triggerText = ";fine"
        #expect(model.warningMessage == nil)
        await model.save()
        #expect(model.phase == .saved)
        #expect(rig.huds.value.isEmpty)
        #expect(try await rig.storedTriggers() == [w395Id: ";fine"])
    }

    // Boundary: with unknown text but neither trigger nor hotkey pending, nothing would paste it, so no warning.
    @Test func unknownTextWithNoBindingShowsNoWarning() async throws {
        let rig = try await W395Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed("Hi {foo}")
        let model = await rig.loaded()
        #expect(model.warningMessage == nil)
        #expect(rig.huds.value.isEmpty)
    }
}
