import FlotsamBase
import FlotsamShortcuts
import FlotsamStorage
import Foundation
import GRDB
import Testing
@testable import FlotsamStorage

// FRD-005 8T contract tests, slice S8 (template variables), the save-time half of OC-5113 and OC-5114 (FR-005-17,
// AC-005-17): an item whose text holds an unknown variable or a bad format saves with a trigger, and the user is told
// once with the TRG-VAL-005 catalogue sentence. The `validate` and literal-expansion halves are in
// FlotsamPasteTests/FRD005ContractTestsVariables. Real editor model, real GRDB database; persistence is read back
// through a FRESH database instance (B4). Expected strings are literals.

private final class S8Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
private final class S8Registrar: HotkeyRegistrar {
    private var next: UInt32 = 1
    func register(_ chord: Chord, handler: @escaping @MainActor () -> Void) -> FlotsamResult<HotkeyRegistration> {
        defer { next += 1 }
        return .success(HotkeyRegistration(rawValue: next))
    }
    func unregister(_ registration: HotkeyRegistration) {}
    func unregisterAll() {}
}

private let s8Id = UUID(uuidString: "00000000-0000-0000-0000-0000000000A8")!
private let s8Sentence = "An unknown variable was left as plain text."

@MainActor
private final class S8Rig {
    let database: FlotsamDatabase
    let registry = ShortcutRegistry(registrar: S8Registrar())
    let huds = S8Box<[String]>([])
    let reports = S8Box<[FlotsamError]>([])
    private let root: URL

    static func make() async throws -> S8Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-frd005-s8-\(UUID().uuidString)")
        return S8Rig(database: try await FlotsamDatabase.open(folder: root).get(), root: root)
    }

    private init(database: FlotsamDatabase, root: URL) {
        self.database = database
        self.root = root
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func seed(_ text: String) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize,
                                      pinned, updatedAt)
                    VALUES (?, 'text', ?, ?, 'key-s8', ?, ?, 0, 0, ?)
                    """,
                arguments: [s8Id.uuidString, now, now, text, text, now])
        }
    }

    func loaded() async -> ItemBindingsEditorModel {
        let huds = huds, reports = reports
        let model = ItemBindingsEditorModel(
            itemId: s8Id,
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
@Suite struct FRD005ContractTestsVariablesSave {
    // Red if a warning blocks the save, the sentence is another text, or the user is not told.
    @Test("OC-5113 saving 'A {foo} B {date:@@}' with trigger ';u1' warns with the TRG-VAL-005 sentence and still saves")
    func oc5113_saveWarnsAndSaves() async throws {
        // given: an item whose text holds an unknown variable and a bad format, and nothing bound yet
        let rig = try await S8Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed("A {foo} B {date:@@}")
        let model = await rig.loaded()
        #expect(try await rig.storedTriggers().isEmpty)
        // when: the user types the trigger and saves
        model.triggerText = ";u1"
        let inline = model.warningMessage
        await model.save()
        // then: one warning with the catalogue sentence, saved, the trigger is stored (fresh read), nothing reported as an error
        #expect(inline == s8Sentence)
        #expect(model.phase == .saved)
        #expect(rig.huds.value == [s8Sentence])
        #expect(try await rig.storedTriggers() == [s8Id: ";u1"])
        #expect(rig.reports.value.isEmpty)
    }

    // Red if the 32-character ceiling is not part of the warning, or the warning blocks the save.
    @Test("OC-5114 saving '{clipboard:x}' and a 33-character date format with a trigger warns and saves; a 32-character format is silent")
    func oc5114_saveFormatCeiling() async throws {
        // given: an item with '{clipboard:x}' and a 33-character format
        let rig = try await S8Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed("{clipboard:x} {date:\(String(repeating: "y", count: 33))}")
        let model = await rig.loaded()
        // when: bound and saved
        model.triggerText = ";u2"
        let inline = model.warningMessage
        await model.save()
        // then: warned once and stored
        #expect(inline == s8Sentence)
        #expect(rig.huds.value == [s8Sentence])
        #expect(model.phase == .saved)
        #expect(try await rig.storedTriggers() == [s8Id: ";u2"])
    }

    @Test("OC-5114 boundary: a 32-character date format is a valid variable, so no warning and no HUD")
    func oc5114_thirtyTwoIsSilent() async throws {
        // given: a 32-character format
        let rig = try await S8Rig.make()
        defer { rig.cleanUp() }
        try await rig.seed("{date:\(String(repeating: "y", count: 32))}")
        let model = await rig.loaded()
        // when
        model.triggerText = ";u3"
        await model.save()
        // then
        #expect(model.warningMessage == nil)
        #expect(rig.huds.value.isEmpty)
        #expect(model.phase == .saved)
        #expect(try await rig.storedTriggers() == [s8Id: ";u3"])
    }
}
