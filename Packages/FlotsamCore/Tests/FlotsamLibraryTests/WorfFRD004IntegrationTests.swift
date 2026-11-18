import FlotsamBase
import FlotsamPaste
import Foundation
import GRDB
import Testing
@testable import FlotsamLibrary
@testable import FlotsamStorage

// Worf's independent FRD-004 verification of the Library organize wrappers over a REAL FlotsamDatabase. The builder's
// LibraryOrganizeTests drive the model against a scripted fake store, which cannot catch a wrong id, a wrong refresh or a
// wrong row mapping between the model and SQLite. These do. State is read back through a fresh read-only connection.
// Each test names its OC and the change that turns it red.

private let integrationClassifiers = ItemClassifiers(
    editedText: { ItemClassification(kind: $0.hasPrefix("https://") ? .link : .text, contentKey: "edit:" + $0) },
    fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) })

private func n(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))! }

private func number(_ id: UUID) -> Int { Int(String(id.uuidString.suffix(12)))! }

@MainActor
private final class Rig {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("worf-lib-\(UUID().uuidString)")
    let database: FlotsamDatabase
    let model: LibraryViewModel
    let organizer: LibraryOrganizer
    let reported = Reported()
    let prefs = FakePreferences()

    @MainActor final class Reported { var errors: [FlotsamError] = [] }

    struct Item {
        var n: Int
        var kind: ItemKind = .text
        /// Hours old, so a smaller number is more recent.
        var hours: Int
        var pinned = false
        var trigger: String?
        var hotkey: Int?
        var text: String?
        var members: [String] = []
    }

    init(_ items: [Item]) async throws {
        let log = SilentLog()
        database = try await FlotsamDatabase.open(folder: root, logSink: log).get()
        let reported = self.reported
        organizer = LibraryOrganizer(store: database, classifiers: integrationClassifiers, report: { reported.errors.append($0) })
        model = LibraryViewModel(
            source: database, paster: FakePaster(), host: FakeHost(), preferences: prefs,
            effects: LibraryEffects(report: { reported.errors.append($0) }), organizer: organizer)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await database.pool.write { db in
            for item in items {
                let id = n(item.n).uuidString
                let text = item.text ?? (item.kind == .bundle ? nil : "item \(item.n)")
                let copied = now - Int64(item.hours) * 3_600_000
                try db.execute(
                    sql: """
                        INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize, pinned,
                                          updatedAt, hotkeyCode, hotkeyModifiers, "trigger")
                        VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        id, item.kind.rawValue, copied, copied, "key-\(item.n)", text, text ?? "", item.pinned ? 1 : 0, copied,
                        item.hotkey, item.hotkey == nil ? nil : 1, item.trigger,
                    ])
                for (ordinal, path) in item.members.enumerated() {
                    try db.execute(
                        sql: "INSERT INTO bundleMember (itemId, ordinal, path, bookmark, isDirectory) VALUES (?, ?, ?, NULL, 0)",
                        arguments: [id, ordinal, path])
                }
            }
        }
        await model.open(target: FrontmostApp(bundleId: "com.apple.TextEdit", processId: 1))
    }

    final class SilentLog: LogSink, @unchecked Sendable { func write(_ record: LogRecord) {} }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// A fresh read-only connection, so a test sees what is on disk and not what the writing connection remembers.
    func fresh<T>(_ body: (Database) throws -> T) throws -> T {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: root.appendingPathComponent("flotsam.sqlite").path, configuration: configuration).read(body)
    }

    func ids() throws -> Set<Int> {
        try fresh { db in Set(try String.fetchAll(db, sql: "SELECT id FROM item").map { Int(String($0.suffix(12)))! }) }
    }

    func count(_ table: String) throws -> Int { try fresh { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 } }

    var listed: [Int] { model.loadedRows.map { number($0.id) } }

    func select(_ numbers: Int...) {
        model.select(id: n(numbers[0]))
        for value in numbers.dropFirst() { model.toggle(id: n(value)) }
    }

    func injectFailure(on table: String, whenCountAtLeast threshold: Int) async throws {
        try await database.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER inject_failure BEFORE INSERT ON \(table) WHEN (SELECT COUNT(*) FROM \(table)) >= \(threshold)
                BEGIN SELECT RAISE(ABORT, 'injected'); END
                """)
        }
    }
}

@MainActor
@Suite struct WorfFRD004IntegrationTests {

    // OC-4001, OC-4002. Red if togglePinSelected acts on the wrong ids or does not refresh the rows the user reads.
    @Test("OC-4001 given a pinned and an unpinned item selected, when pin toggles, then both read pinned; toggling again unpins both")
    func pinThroughModel() async throws {
        let rig = try await Rig([.init(n: 1, hours: 1, pinned: true), .init(n: 2, hours: 2), .init(n: 3, hours: 3)])
        defer { rig.cleanUp() }
        rig.select(1, 2)
        #expect(rig.model.selection == [n(1), n(2)])

        #expect(await rig.model.togglePinSelected() == true)

        #expect(rig.model.loadedRows.filter(\.isPinned).map { number($0.id) } == [1, 2])
        #expect(try rig.fresh { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE pinned = 1") } == 2)
        #expect(rig.listed == [1, 2, 3])
        #expect(rig.model.selection == [n(1), n(2)])

        #expect(await rig.model.togglePinSelected() == false)

        #expect(rig.model.loadedRows.filter(\.isPinned).isEmpty)
        #expect(try rig.fresh { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE pinned = 1") } == 0)
        #expect(rig.reported.errors.isEmpty)
    }

    // B6: nothing selected. Red if the wrapper writes with an empty selection.
    @Test("OC-4001 given no selection, when pin toggles, then nothing is called and nothing changes")
    func pinWithNoSelection() async throws {
        let rig = try await Rig([.init(n: 1, hours: 1)])
        defer { rig.cleanUp() }
        rig.select(1)
        rig.model.toggle(id: n(1))
        #expect(rig.model.selection.isEmpty)
        let loaded = rig.listed

        let none = await rig.model.togglePinSelected()

        #expect(none == nil)
        #expect(rig.listed == loaded)
        #expect(try rig.fresh { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE pinned = 1") } == 0)
    }

    // OC-4070, OC-4064. Red if the model picks a wrong survivor, leaves a deleted row listed, or deletes the wrong ids.
    @Test("OC-4070 given P,Q,R,S with Q and R selected, when deleted, then S is selected, P and S remain, rows and database agree")
    func deleteSelectsNextRow() async throws {
        let rig = try await Rig((1...4).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        rig.select(2, 3)

        let removed = await rig.model.deleteSelected()

        #expect(Set(removed ?? []) == [n(2), n(3)])
        #expect(rig.listed == [1, 4])
        #expect(rig.model.totalCount == 2)
        #expect(rig.model.selection == [n(4)])
        #expect(try rig.ids() == [1, 4])
        #expect(rig.reported.errors.isEmpty)
    }

    // OC-4070 fallback: no row after, so the last remaining row before the deleted one.
    @Test("OC-4070 given the last row selected, when deleted, then the row before it is selected")
    func deleteLastRowSelectsPrevious() async throws {
        let rig = try await Rig((1...3).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        rig.select(3)

        _ = await rig.model.deleteSelected()

        #expect(rig.listed == [1, 2])
        #expect(rig.model.selection == [n(2)])
        #expect(try rig.ids() == [1, 2])
    }

    // OC-4071. Red if emptying the library leaves a stale row, stale count, or a stale selection.
    @Test("OC-4071 given a one-item library, when deleted, then the list, count and selection are empty")
    func deleteOnlyItem() async throws {
        let rig = try await Rig([.init(n: 1, hours: 1)])
        defer { rig.cleanUp() }
        rig.select(1)

        let removed = await rig.model.deleteSelected()

        #expect(removed == [n(1)])
        #expect(rig.listed == [])
        #expect(rig.model.totalCount == 0)
        #expect(rig.model.selection.isEmpty)
        #expect(rig.model.isHistoryEmpty)
        #expect(try rig.count("item") == 0)
    }

    // OC-4063, 4064, 4065, 4072, 4075/4076 policy over rows the real query produced (so hasTrigger/hasShortcut mapping counts).
    @Test("OC-4065 given real rows, when policy is asked, then confirmation and availability follow pin, trigger, hotkey, count and kind")
    func policyOverRealRows() async throws {
        let rig = try await Rig([
            .init(n: 1, hours: 1), .init(n: 2, hours: 2, pinned: true), .init(n: 3, hours: 3, trigger: ";sig"),
            .init(n: 4, hours: 4, hotkey: 7), .init(n: 5, kind: .bundle, hours: 5, members: ["/a/1", "/a/2"]),
            .init(n: 6, kind: .bundle, hours: 6, members: ["/b/1"]), .init(n: 7, kind: .file, hours: 7, text: "f"),
        ])
        defer { rig.cleanUp() }
        func row(_ value: Int) -> ItemRow { rig.model.loadedRows.first { $0.id == n(value) }! }

        #expect(!LibraryOrganizer.deleteNeedsConfirmation([row(1)]))
        #expect(LibraryOrganizer.deleteNeedsConfirmation([row(2)]))
        #expect(LibraryOrganizer.deleteNeedsConfirmation([row(3)]))
        #expect(LibraryOrganizer.deleteNeedsConfirmation([row(4)]))
        #expect(LibraryOrganizer.deleteNeedsConfirmation([row(1), row(7)]))
        #expect(!LibraryOrganizer.deleteNeedsConfirmation([]))

        #expect(LibraryOrganizer.canUngroup([row(5)]))
        #expect(!LibraryOrganizer.canUngroup([row(7)]))
        #expect(!LibraryOrganizer.canUngroup([row(5), row(6)]))
        #expect(!LibraryOrganizer.canUngroup([row(5), row(1)]))
        #expect(!LibraryOrganizer.canUngroup([]))

        #expect(LibraryOrganizer.canEdit([row(1)]))
        #expect(!LibraryOrganizer.canEdit([row(5)]))
        #expect(!LibraryOrganizer.canEdit([row(1), row(2)]))

        _ = try await rig.database.setNote("n", for: n(5)).get()
        let withNote = await rig.organizer.note(of: n(5))
        let without = await rig.organizer.note(of: n(6))
        #expect(withNote == "n")
        #expect(without == nil)
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(row(5), hasNote: withNote != nil))
        #expect(!LibraryOrganizer.ungroupNeedsConfirmation(row(6), hasNote: without != nil))
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(row(2), hasNote: false))
    }

    // OC-4057. Red if edit moves the item (lastCopiedAt touched), or drops pin, tags, note or hotkey on the refresh.
    @Test("OC-4057 given a pinned tagged noted hotkeyed item at position 4, when edited, then position and every attribute survive")
    func editKeepsPositionAndAttributes() async throws {
        let rig = try await Rig((1...6).map { .init(n: $0, hours: $0, pinned: $0 == 4, hotkey: $0 == 4 ? 9 : nil) })
        defer { rig.cleanUp() }
        rig.select(4)
        _ = await rig.model.createTagOnSelection(name: "Keep")
        _ = await rig.model.saveNote("a note", for: n(4))
        #expect(rig.listed == [1, 2, 3, 4, 5, 6])

        let kind = await rig.model.saveEdit(text: "https://example.com")

        #expect(kind == .link)
        #expect(rig.listed == [1, 2, 3, 4, 5, 6])
        let edited = try #require(rig.model.loadedRows.first { $0.id == n(4) })
        #expect(edited.isPinned && edited.hasShortcut)
        #expect(edited.tagNames == ["Keep"])
        #expect(edited.kind == .link)
        #expect(edited.primaryLine == "https://example.com")
        #expect(await rig.organizer.note(of: n(4)) == "a note")
        #expect(try rig.fresh { try String.fetchOne($0, sql: "SELECT plainText FROM item WHERE id = ?", arguments: [n(4).uuidString]) } == "https://example.com")
        #expect(rig.reported.errors.isEmpty)
    }

    // OC-4051 / FR-004-07 rejection through the model: stored text unchanged, no refresh side effects, nothing thrown.
    @Test("OC-4051 given an item selected, when whitespace-only text is saved, then it returns nil and the stored text is unchanged")
    func editRejectedLeavesItem() async throws {
        let rig = try await Rig([.init(n: 1, hours: 1, text: "keep me")])
        defer { rig.cleanUp() }
        rig.select(1)

        let kind = await rig.model.saveEdit(text: "  \n ")

        #expect(kind == nil)
        #expect(try rig.fresh { try String.fetchOne($0, sql: "SELECT plainText FROM item") } == "keep me")
        #expect(rig.model.loadedRows.map(\.primaryLine) == ["keep me"])
        #expect(rig.reported.errors.map(\.code) == [.orgVal003])
    }

    // OC-4076, FR-004-11. Red if the new items are not selected, are out of member order, or the bundle row lingers.
    @Test("OC-4076 given a 3-member bundle, when ungrouped, then 3 items replace it in member order and are selected")
    func ungroupThroughModel() async throws {
        let rig = try await Rig([
            .init(n: 1, hours: 1), .init(n: 2, kind: .bundle, hours: 2, members: ["/z/c.txt", "/z/a.txt", "/z/b.txt"]), .init(n: 3, hours: 3),
        ])
        defer { rig.cleanUp() }
        rig.select(2)

        let created = try #require(await rig.model.ungroupSelected())

        #expect(created.count == 3)
        #expect(rig.model.totalCount == 5)
        #expect(!rig.model.loadedRows.contains { $0.id == n(2) })
        #expect(rig.model.selection == Set(created))
        let keys = try rig.fresh { db in
            try created.map { try String.fetchOne(db, sql: "SELECT contentKey FROM item WHERE id = ?", arguments: [$0.uuidString]) ?? "" }
        }
        #expect(keys == ["file:/z/c.txt", "file:/z/a.txt", "file:/z/b.txt"])
        #expect(Set(rig.model.loadedRows.map(\.id)).isSuperset(of: created))
        // Each new file item carries its own single member row; the bundle's rows went with it.
        #expect(try rig.count("bundleMember") == 3)
        #expect(try rig.fresh { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bundleMember WHERE itemId = ?", arguments: [n(2).uuidString]) } == 0)
        #expect(try rig.count("item") == 5)
        #expect(try rig.fresh { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE kind = 'file'") } == 3)
    }

    // OC-4080 through the model. Red if ungroup is not one transaction, or the model refreshes/selects after a failure.
    @Test("OC-4080 given a 4-member bundle and a failure on the 3rd insert, when ungrouped, then nothing changes and STO-DB-001 is reported once")
    func ungroupFailureThroughModel() async throws {
        let rig = try await Rig([.init(n: 1, kind: .bundle, hours: 1, members: ["/a/1", "/a/2", "/a/3", "/a/4"]), .init(n: 2, hours: 2)])
        defer { rig.cleanUp() }
        rig.select(1)
        try await rig.database.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER inject_failure BEFORE INSERT ON item WHEN NEW.contentKey = 'file:/a/3'
                BEGIN SELECT RAISE(ABORT, 'injected'); END
                """)
        }

        let created = await rig.model.ungroupSelected()

        #expect(created == nil)
        #expect(rig.reported.errors.map(\.code) == [.stoDb001])
        #expect(rig.listed == [1, 2])
        #expect(rig.model.selection == [n(1)])
        #expect(try rig.ids() == [1, 2])
        #expect(try rig.count("bundleMember") == 4)
    }

    // OC-4101 through the model. Red if the model reports twice, refreshes with a half-applied state, or loses the selection.
    @Test("OC-4101 given 500 items selected and a failure partway, when tagged, then no row carries the tag and STO-DB-001 is reported once")
    func tagFailureThroughModel() async throws {
        let rig = try await Rig((1...500).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        let tag = try await rig.database.createTag(name: "bulk").get()
        try await rig.injectFailure(on: "itemTag", whenCountAtLeast: 249)
        for value in 1...500 { rig.model.toggle(id: n(value)) }
        let selected = rig.model.selection.count
        #expect(selected > 0)

        let applied = await rig.model.toggleTagOnSelection(tag)

        #expect(applied == nil)
        #expect(rig.reported.errors.map(\.code) == [.stoDb001])
        #expect(try rig.count("itemTag") == 0)
        #expect(rig.model.loadedRows.allSatisfy { $0.tagNames.isEmpty })
        #expect(rig.model.selection.count == selected)
    }

    // OC-4029, FR-004-04. Red if deleteTag leaves the sidebar filtered to a dead tag or removes items.
    @Test("OC-4029 given the list filtered to a tag on 2 of 4 items, when the tag is deleted, then the filter is All and all 4 items list")
    func deleteTagWhileFiltered() async throws {
        let rig = try await Rig((1...4).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        rig.select(1, 2)
        let tag = try #require(await rig.model.createTagOnSelection(name: "Two"))
        rig.model.select(filter: .tag(tag))
        await rig.model.settled()
        #expect(rig.listed == [1, 2])
        #expect(try rig.count("itemTag") == 2)

        let removed = await rig.model.deleteTag(tag)

        #expect(removed == 2)
        #expect(rig.model.filter == .all)
        #expect(rig.listed == [1, 2, 3, 4])
        #expect(try rig.count("tag") == 0)
        #expect(try rig.count("item") == 4)
        #expect(rig.reported.errors.isEmpty)
    }

    // OC-4087: pin and organise actions never change the active filter.
    @Test("OC-4087 given a tag filter active, when an item is pinned, then the filter stays on the tag and only its items list")
    func filterSurvivesPin() async throws {
        let rig = try await Rig((1...4).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        rig.select(1, 3)
        let tag = try #require(await rig.model.createTagOnSelection(name: "Odd"))
        rig.model.select(filter: .tag(tag))
        await rig.model.settled()
        rig.select(3)

        _ = await rig.model.togglePinSelected()

        #expect(rig.model.filter == .tag(tag))
        #expect(rig.listed == [1, 3])
        #expect(rig.model.loadedRows.filter(\.isPinned).map { number($0.id) } == [3])
    }

    // OC-4095 over the real query. Red if cycleSort advances the key but the rows are not re-ordered from storage.
    @Test("OC-4095 given items with distinct use counts, when the sort cycles, then rows reorder from the database and the choice persists")
    func sortCycleReordersRealRows() async throws {
        let rig = try await Rig((1...4).map { .init(n: $0, hours: $0, text: ["delta", "alpha", "charlie", "bravo"][$0 - 1]) })
        defer { rig.cleanUp() }
        for (value, count) in [(1, 0), (2, 1), (3, 9), (4, 5)] {
            try await rig.database.pool.write { try $0.execute(sql: "UPDATE item SET pasteCount = ? WHERE id = ?", arguments: [count, n(value).uuidString]) }
        }
        await rig.model.refresh()
        #expect(rig.listed == [1, 2, 3, 4])

        rig.model.cycleSort()
        await rig.model.settled()
        #expect(rig.listed == [4, 3, 2, 1])
        #expect(rig.prefs.sort == .oldest)

        rig.model.cycleSort()
        await rig.model.settled()
        #expect(rig.listed == [3, 4, 2, 1])
        #expect(rig.prefs.sort == .mostUsed)

        rig.model.cycleSort()
        await rig.model.settled()
        #expect(rig.listed == [2, 4, 3, 1])
        #expect(rig.prefs.sort == .alphabetical)

        rig.model.cycleSort()
        await rig.model.settled()
        #expect(rig.listed == [1, 2, 3, 4])
        #expect(rig.prefs.sort == .recent)
    }
}

// MARK: - FRD-004 second pass: tag rules, filter + query, confirm-time re-check, model-level performance

@MainActor private func code(_ rig: Rig) -> [String] { rig.reported.errors.map(\.code.rawValue) }

@MainActor
@Suite struct WorfFRD004RulesIntegrationTests {

    // OC-4201 (AC-004-02). Red if the model path skips validation, folds only case and not diacritics, or leaves a tag or link
    // behind on a rejected name.
    @Test("OC-4201 given tag Work and Résumé, when work, RESUME, 33 chars, empty and spaces are created, then each is ORG-VAL-001 and nothing is stored")
    func tagNameRulesThroughModel() async throws {
        let rig = try await Rig((1...2).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        rig.select(1)
        let work = try #require(await rig.model.createTagOnSelection(name: "Work"))
        let resume = try #require(await rig.model.createTagOnSelection(name: "Résumé"))
        #expect(try rig.count("tag") == 2)
        #expect(try rig.count("itemTag") == 2)
        rig.select(2)

        let attempts = ["work", "WORK ", "resume", "RESUME", String(repeating: "x", count: 33), "", "   "]
        var created: [Int64?] = []
        for name in attempts { created.append(await rig.model.createTagOnSelection(name: name)) }

        #expect(created.allSatisfy { $0 == nil })
        #expect(code(rig) == Array(repeating: "ORG-VAL-001", count: 7))
        #expect(try rig.count("tag") == 2)
        #expect(try rig.count("itemTag") == 2, "a rejected name must not apply anything to the selected item")
        #expect(try rig.fresh { try String.fetchAll($0, sql: "SELECT name FROM tag ORDER BY id") } == ["Work", "Résumé"])
        #expect(work != resume)
    }

    // OC-4202. Red if the 32 boundary is off by one, or a duplicate check compares against the tag being renamed.
    @Test("OC-4202 given a 32-char name, when created, then it is stored; renaming a tag to another's name is rejected and to its own case is allowed")
    func tagNameBoundaryAndRename() async throws {
        let rig = try await Rig([.init(n: 1, hours: 1)])
        defer { rig.cleanUp() }
        rig.select(1)
        let thirtyTwo = String(repeating: "q", count: 32)
        let long = try #require(await rig.model.createTagOnSelection(name: thirtyTwo))
        let other = try #require(await rig.model.createTagOnSelection(name: "Other"))
        #expect(rig.reported.errors.isEmpty)

        let clash = await rig.model.renameTag(other, to: thirtyTwo.uppercased())
        let sameCase = await rig.model.renameTag(other, to: "OTHER")

        #expect(clash == false)
        #expect(sameCase == true)
        #expect(code(rig) == ["ORG-VAL-001"])
        #expect(try rig.fresh { try String.fetchAll($0, sql: "SELECT name FROM tag ORDER BY id") } == [thirtyTwo, "OTHER"])
        #expect(long != other)
    }

    // OC-4203 (AC-004-03, per item). Red if the cap is 11, is checked after the write, or a rejected multi-item action
    // applies to the items that were under the cap.
    @Test("OC-4203 given item 1 with 10 tags, when an 11th is toggled on items 1 and 2, then ORG-LIM-001 and neither item changes")
    func eleventhTagRejectedAtomically() async throws {
        let rig = try await Rig((1...2).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        var tags: [Int64] = []
        for value in 1...11 { tags.append(try await rig.database.createTag(name: "t\(value)").get()) }
        rig.select(1)
        for tag in tags.prefix(9) { #expect(await rig.model.toggleTagOnSelection(tag) == true) }
        #expect(try rig.count("itemTag") == 9)
        #expect(await rig.model.toggleTagOnSelection(tags[9]) == true, "the 10th is the last one allowed")
        #expect(try rig.count("itemTag") == 10)
        rig.select(1, 2)

        let result = await rig.model.toggleTagOnSelection(tags[10])

        #expect(result == nil)
        #expect(code(rig) == ["ORG-LIM-001"])
        #expect(try rig.count("itemTag") == 10)
        #expect(try rig.fresh { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM itemTag WHERE itemId = ?", arguments: [n(2).uuidString]) } == 0)
    }

    // OC-4204. Red if Create-and-apply leaves the new tag behind when the apply is rejected (FR-004-03).
    @Test("OC-4204 given item 1 with 10 tags, when a new tag is created on it, then ORG-LIM-001 and no 11th tag exists")
    func createOnFullItemLeavesNoOrphan() async throws {
        let rig = try await Rig([.init(n: 1, hours: 1)])
        defer { rig.cleanUp() }
        rig.select(1)
        for value in 1...10 { _ = try #require(await rig.model.createTagOnSelection(name: "t\(value)")) }
        #expect(try rig.count("tag") == 10)

        let created = await rig.model.createTagOnSelection(name: "t11")

        #expect(created == nil)
        #expect(code(rig) == ["ORG-LIM-001"])
        #expect(try rig.count("tag") == 10)
        #expect(try rig.count("itemTag") == 10)
    }

    // OC-4205 (AC-004-03, library). Red if the library cap is 101 or ORG-LIM-002 is reported as ORG-VAL-001.
    @Test("OC-4205 given 100 tags, when a 101st is created on the selection, then ORG-LIM-002 and the selected item has no tag")
    func hundredAndFirstTagRejected() async throws {
        let rig = try await Rig([.init(n: 1, hours: 1)])
        defer { rig.cleanUp() }
        for value in 1...100 { _ = try await rig.database.createTag(name: "tag \(value)").get() }
        rig.select(1)

        let created = await rig.model.createTagOnSelection(name: "tag 101")

        #expect(created == nil)
        #expect(code(rig) == ["ORG-LIM-002"])
        #expect(try rig.count("tag") == 100)
        #expect(try rig.count("itemTag") == 0)
    }

    // OC-4210 (AC-004-11). Red if the filter and the query are not combined, All also clears the query, or a second filter
    // adds to the first instead of replacing it.
    @Test("OC-4210 given a Pinned filter, when a query is typed, All chosen, then a Tag chosen, then exactly one filter applies and the query persists")
    func oneFilterAtATimeQueryIndependent() async throws {
        let rig = try await Rig([
            .init(n: 1, hours: 1, pinned: true, text: "apple red"), .init(n: 2, hours: 2, text: "apple green"),
            .init(n: 3, hours: 3, pinned: true, text: "banana yellow"), .init(n: 4, hours: 4, text: "cherry apple"),
        ])
        defer { rig.cleanUp() }
        rig.select(2, 3)
        let tag = try #require(await rig.model.createTagOnSelection(name: "Mix"))

        rig.model.select(filter: .pinned)
        await rig.model.settled()
        #expect(rig.listed == [1, 3])

        rig.model.setSearchText("apple")
        await rig.model.settled()
        #expect(rig.model.filter == .pinned)
        #expect(rig.listed == [1], "the query narrows within the filter: pinned AND apple")

        rig.model.select(filter: .all)
        await rig.model.settled()
        #expect(rig.model.filter == .all)
        #expect(rig.model.searchText == "apple")
        #expect(rig.listed == [1, 2, 4], "All clears the filter, not the query")

        rig.model.select(filter: .tag(tag))
        await rig.model.settled()
        #expect(rig.model.filter == .tag(tag))
        #expect(rig.listed == [2], "the tag replaces any earlier filter; only tagged apple items list")

        rig.model.setSearchText("")
        await rig.model.settled()
        #expect(rig.model.filter == .tag(tag), "clearing the query keeps the filter")
        #expect(rig.listed == [2, 3])
    }

    // OC-4220 (FR-004-09 re-check, over the real DB). Red if the confirmed set is compared with contains/isSubset, or ignored.
    @Test("OC-4220 given a confirmed delete of item 1, when the selection is now {2} or {1,2}, then nothing is deleted; when it is {1}, only 1 goes")
    func confirmedDeleteReChecksSelection() async throws {
        let rig = try await Rig((1...4).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        let asked: Set<UUID> = [n(1)]

        rig.select(2)
        #expect(await rig.model.deleteSelected(expecting: asked) == nil)
        rig.select(1, 2)
        #expect(await rig.model.deleteSelected(expecting: asked) == nil)
        rig.model.select(id: n(1))
        rig.model.toggle(id: n(1))
        #expect(rig.model.selection.isEmpty)
        #expect(await rig.model.deleteSelected(expecting: asked) == nil)

        #expect(try rig.ids() == [1, 2, 3, 4])
        #expect(rig.reported.errors.isEmpty)

        rig.select(1)
        let removed = await rig.model.deleteSelected(expecting: asked)

        #expect(removed == [n(1)])
        #expect(try rig.ids() == [2, 3, 4])
        #expect(rig.model.selection == [n(2)])
    }

    // OC-4221 (FR-004-11 re-check). Red if the expected bundle is ignored, or a multi-selection containing it passes.
    @Test("OC-4221 given a confirmed ungroup of bundle 1, when bundle 3 or {1,3} is selected, then nothing changes; when 1 is, it ungroups")
    func confirmedUngroupReChecksSelection() async throws {
        let rig = try await Rig([
            .init(n: 1, kind: .bundle, hours: 1, members: ["/a/1", "/a/2"]),
            .init(n: 2, hours: 2),
            .init(n: 3, kind: .bundle, hours: 3, members: ["/b/1", "/b/2", "/b/3"]),
        ])
        defer { rig.cleanUp() }

        rig.select(3)
        #expect(await rig.model.ungroupSelected(expecting: n(1)) == nil)
        rig.select(1, 3)
        #expect(await rig.model.ungroupSelected(expecting: n(1)) == nil)

        #expect(try rig.ids() == [1, 2, 3])
        #expect(try rig.count("bundleMember") == 5)
        #expect(rig.reported.errors.isEmpty)

        rig.select(1)
        let created = await rig.model.ungroupSelected(expecting: n(1))

        #expect(created?.count == 2)
        #expect(try rig.count("item") == 4)
        #expect(try rig.fresh { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE id = ?", arguments: [n(1).uuidString]) } == 0)
        #expect(try rig.fresh { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE id = ?", arguments: [n(3).uuidString]) } == 1)
    }

    // OC-4230 (AC-004-13 at the model: includes the list refresh the user waits for). Red if an organise action reloads or
    // rescans the whole library per item, or the 500-item tag loops with one read per item.
    @Test("OC-4230 given 10,000 items, when pin, tag and delete repeat through the model, then p95 is under 100 ms and tagging 500 is under 1 s")
    func modelPerformanceAtTenThousand() async throws {
        let rig = try await Rig((1...10_000).map { .init(n: $0, hours: $0) })
        defer { rig.cleanUp() }
        #expect(try rig.count("item") == 10_000)
        let tag = try await rig.database.createTag(name: "perf").get()
        let clock = ContinuousClock()
        func millis(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        func p95(_ samples: [Double]) -> Double { samples.sorted()[Int((Double(samples.count) * 0.95).rounded(.up)) - 1] }

        var pin: [Double] = [], toggle: [Double] = [], delete: [Double] = []
        for step in 1...20 {
            rig.model.select(id: n(step * 10))
            pin.append(millis(await clock.measure { _ = await rig.model.togglePinSelected() }))
            rig.model.select(id: n(step * 10 + 1))
            toggle.append(millis(await clock.measure { _ = await rig.model.toggleTagOnSelection(tag) }))
            rig.model.select(id: n(step * 10 + 2))
            delete.append(millis(await clock.measure { _ = await rig.model.deleteSelected() }))
        }
        rig.model.select(id: n(5_001))
        for value in 5_002...5_500 { rig.model.toggle(id: n(value)) }
        #expect(rig.model.selection.count == 500)
        let bulk = millis(await clock.measure { _ = await rig.model.toggleTagOnSelection(tag) })

        #expect(try rig.fresh { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE pinned = 1") } == 20)
        #expect(try rig.count("item") == 9_980)
        #expect(try rig.count("itemTag") == 520)
        #expect(rig.reported.errors.isEmpty)
        #expect(p95(pin) < 100, "pin p95 \(p95(pin)) ms")
        #expect(p95(toggle) < 100, "tag p95 \(p95(toggle)) ms")
        #expect(p95(delete) < 100, "delete p95 \(p95(delete)) ms")
        #expect(bulk < 1000, "bulk tag \(bulk) ms")
    }
}

// TASK-392 (FR-004-01): the context-menu Pin/Unpin label must say what the action will do. These run the label predicate
// (`pinActionUnpins`) and then the action as the row's `act` helper does (select the row when it is outside the selection,
// then `togglePinSelected`), against a REAL database, and read pinned state back through a fresh connection. Red if the
// label reads only the clicked row, or if the label and the applied state disagree.
@MainActor
@Suite struct WorfPinLabelTests {
    private func pinned(_ rig: Rig) throws -> Set<Int> {
        try rig.fresh { db in Set(try String.fetchAll(db, sql: "SELECT id FROM item WHERE pinned = 1").map { Int(String($0.suffix(12)))! }) }
    }

    /// Right-click on `row`: the label, then the action, as the app does. Returns (label says Unpin, state the action applied).
    private func rightClick(_ rig: Rig, row: Int) async -> (unpins: Bool, applied: Bool?) {
        let isPinned = rig.model.loadedRows.first { $0.id == n(row) }!.isPinned
        let unpins = rig.model.pinActionUnpins(menuRowID: n(row), isPinned: isPinned)
        if !rig.model.selection.contains(n(row)) { rig.model.select(id: n(row)) }
        return (unpins, await rig.model.togglePinSelected())
    }

    private func rig() async throws -> Rig {
        try await Rig([.init(n: 1, hours: 1, pinned: true), .init(n: 2, hours: 2), .init(n: 3, hours: 3, pinned: true),
                       .init(n: 4, hours: 4), .init(n: 5, hours: 5, pinned: true)])
    }

    @Test("OC-4003 given one pinned row selected, when the menu opens on it, then the label says Unpin and the action unpins only it")
    func singlePinned() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        rig.select(1)
        let result = await rightClick(rig, row: 1)
        #expect(result.unpins == true)
        #expect(result.applied == false)
        #expect(try pinned(rig) == [3, 5])
    }

    @Test("OC-4003 given one unpinned row selected, then the label says Pin and the action pins only it")
    func singleUnpinned() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        rig.select(2)
        let result = await rightClick(rig, row: 2)
        #expect(result.unpins == false)
        #expect(result.applied == true)
        #expect(try pinned(rig) == [1, 2, 3, 5])
    }

    @Test("OC-4003 given all-pinned multi-selection, then the label says Unpin and every one unpins")
    func allPinned() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        rig.select(1, 3, 5)
        let result = await rightClick(rig, row: 3)
        #expect(result.unpins == true)
        #expect(result.applied == false)
        #expect(try pinned(rig).isEmpty)
    }

    @Test("OC-4003 given all-unpinned multi-selection, then the label says Pin and every one pins")
    func allUnpinned() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        rig.select(2, 4)
        let result = await rightClick(rig, row: 4)
        #expect(result.unpins == false)
        #expect(result.applied == true)
        #expect(try pinned(rig) == [1, 2, 3, 4, 5])
    }

    // The old label read the clicked row only: on the pinned row of a mixed selection it said Unpin while the action pins all.
    @Test("OC-4003 given a mixed selection, when the menu opens on a pinned row or an unpinned row, then both say Pin and the action pins all")
    func mixed() async throws {
        for clicked in [1, 2] {
            let rig = try await rig()
            defer { rig.cleanUp() }
            rig.select(1, 2)
            let result = await rightClick(rig, row: clicked)
            #expect(result.unpins == false, "clicked row \(clicked)")
            #expect(result.applied == true, "clicked row \(clicked)")
            #expect(try pinned(rig) == [1, 2, 3, 5], "clicked row \(clicked)")
        }
    }

    // Right-click outside the selection: the action re-targets to the clicked row alone, so the label reads that row alone.
    @Test("OC-4003 given a pinned selection and a right-click on an unpinned row outside it, then Pin, and only that row changes")
    func outsideSelectionUnpinnedRow() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        rig.select(1, 3)
        let result = await rightClick(rig, row: 4)
        #expect(result.unpins == false)
        #expect(result.applied == true)
        #expect(rig.model.selection == [n(4)])
        #expect(try pinned(rig) == [1, 3, 4, 5])
    }

    @Test("OC-4003 given an unpinned selection and a right-click on a pinned row outside it, then Unpin, and only that row changes")
    func outsideSelectionPinnedRow() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        rig.select(2, 4)
        let result = await rightClick(rig, row: 5)
        #expect(result.unpins == true)
        #expect(result.applied == false)
        #expect(rig.model.selection == [n(5)])
        #expect(try pinned(rig) == [1, 3])
    }

    // B6: nothing selected at all; the label reads the clicked row.
    @Test("OC-4003 given no selection, when the menu opens on a pinned row, then Unpin; on an unpinned row, Pin")
    func noSelection() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        for id in rig.model.selection { rig.model.toggle(id: id) }  // opening a list auto-selects the first row
        #expect(rig.model.selection.isEmpty)
        #expect(rig.model.pinActionUnpins(menuRowID: n(1), isPinned: true) == true)
        #expect(rig.model.pinActionUnpins(menuRowID: n(2), isPinned: false) == false)
        #expect(try pinned(rig) == [1, 3, 5])  // reading the label changed nothing
    }
}
