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
