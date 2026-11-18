import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
import FlotsamStorage
@testable import FlotsamShelf

// FRD-006 contract: the gaps found by auditing the OC ids that pre-existing tests already cite. Each test below
// asserts the part of an oracle then-clause the citing test left unchecked. Real ShelfDropPlanner, real
// IngestActor over a real database in a scratch folder, real ErrorReporter; only the presenter, key-value store,
// clock and log sink are fakes. Every expected value is a literal.

@MainActor
private final class GapPresenter: ErrorPresenter {
    private(set) var huds: [String] = []
    func showHUD(message: String) { huds.append(message) }
    func noticesChanged(_ notices: [Notice]) {}
    func presentFatal(_ error: FlotsamError) {}
}

private final class GapKV: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private final class GapClock: WallClock, @unchecked Sendable {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(for duration: Duration) async {}
}

private final class GapSink: LogSink, @unchecked Sendable {
    func write(_ record: LogRecord) {}
}

@MainActor
private struct GapRig {
    let root: URL
    let files: URL
    let database: FlotsamDatabase
    let presenter: GapPresenter
    let reporter: ErrorReporter
    let settings: SettingsStore
    let service: ShelfDropService

    static func make() async throws -> GapRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-gap-\(UUID().uuidString)")
        let files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let database = try await FlotsamDatabase.open(folder: root.appendingPathComponent("data"), logSink: GapSink()).get()
        let presenter = GapPresenter()
        let reporter = ErrorReporter(presenter: presenter, clock: GapClock(), sink: GapSink())
        let settings = SettingsStore(store: GapKV())
        let service = ShelfDropService(
            ingest: IngestActor(database: database, settings: settings), reporter: reporter, sink: GapSink(),
            dropCompleted: {})
        return GapRig(
            root: root, files: files, database: database, presenter: presenter, reporter: reporter, settings: settings,
            service: service)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func file(_ name: String) throws -> URL {
        let url = files.appendingPathComponent(name)
        try Data(count: 0).write(to: url)
        return url
    }

    @discardableResult
    func dropText(_ text: String, source: SourceApp? = nil, at seconds: TimeInterval) async -> UUID? {
        let rep = PasteboardRepresentation(uti: PasteboardTypes.plainText, data: Data(text.utf8))
        let result = await service.drop(
            types: [PasteboardTypes.plainText], representations: [rep], source: source, originatesInShelf: false,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
        if case .stored(let id, _) = result { return id }
        return nil
    }

    @discardableResult
    func dropFiles(_ urls: [URL], source: SourceApp? = nil, at seconds: TimeInterval) async -> UUID? {
        let reps = urls.map { PasteboardRepresentation(uti: PasteboardTypes.fileURL, data: Data($0.absoluteString.utf8)) }
        let result = await service.drop(
            types: [PasteboardTypes.fileURL], representations: reps, source: source, originatesInShelf: false,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
        if case .stored(let id, _) = result { return id }
        return nil
    }

    func rows() async throws -> [ItemRow] { try await database.items(matching: LibraryQuery()).get().rows }
    func itemCount() async throws -> Int { try await database.count(filter: .all).get() }

    /// Pre-seeds `count` distinct text items so a test can assert a delta against a non-zero N.
    func seed(_ count: Int) async throws -> [UUID] {
        var ids: [UUID] = []
        for index in 0..<count {
            let id = await dropText("seed-\(index)", at: Double(index))
            ids.append(try #require(id))
        }
        return ids
    }
}

@MainActor
@Suite struct Frd006ContractPrecitedGapTests {
    private let finder = SourceApp(bundleId: "com.apple.finder", name: "Finder")
    private let textEdit = SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")

    // OC-6020. Given N items, when a file is dropped on the Shelf the menu-bar icon revealed, then the count is N+1
    // with the file at the top of Recent. Turns red if the drop stores nothing, replaces an item, or does not put
    // the new card first. (The 300 ms dwell and the hold are asserted in ShelfRevealMachineTests.)
    @Test("OC-6020 a file dropped on the menu-bar Shelf makes the count N+1 and sits first in Recent")
    func oc6020_dropAddsOneAndLandsFirst() async throws {
        let rig = try await GapRig.make()
        defer { rig.cleanUp() }
        let seeded = try await rig.seed(2)
        let countBefore = try await rig.itemCount()

        let dropped = try #require(await rig.dropFiles([try rig.file("menu-bar-drop.txt")], at: 10))

        let rows = try await rig.rows()
        #expect(countBefore == 2)
        #expect(try await rig.itemCount() == 3)
        #expect(rows.first?.id == dropped)
        #expect(rows.first?.kind == .file)
        #expect(Set(rows.map(\.id)) == Set(seeded + [dropped]), "both earlier items survive")
    }

    // OC-6040. Given no items, when the Shelf is revealed, then no section header exists and only ui.shelf.empty is
    // shown. Turns red if an empty Shelf still builds a header section, or if the empty-state text changes or is
    // missing from the catalogue (the text resolves to "" when the key is unknown).
    @Test("OC-6040 an empty Shelf has no sections and the empty-state text is the catalogue sentence")
    func oc6040_emptyShelfShowsOnlyTheEmptyText() async {
        let rig = ShelfRig(rows: [])
        await rig.openSticky()

        #expect(rig.model.sections().isEmpty)
        #expect(rig.model.isEmpty)
        #expect(ShelfText.string(ShelfText.empty) == "Shelf is empty. Copy something, or drag an item here to pin it.")
    }

    @Test("OC-6040 one Recent card gives one section and no empty state (boundary 0 to 1)")
    func oc6040_oneCardIsNotEmpty() async {
        let rig = ShelfRig(rows: [makeShelfRow(1)])
        await rig.openSticky()

        #expect(rig.model.sections().map(\.cards.count) == [1])
        #expect(!rig.model.isEmpty)
    }

    // OC-6088. Given text dragged from TextEdit, when it hovers a visible Shelf, then the drop zone is highlighted
    // and the copy badge shows. The planner decides `.accepted` (highlight plus copy badge); the model carries the
    // highlight flag. Turns red if text is refused, or if the Shelf's own drag is also accepted.
    @Test("OC-6088 a text drag is accepted for the highlight and copy badge, the Shelf's own drag is not")
    func oc6088_textDragIsAccepted() async {
        let acceptance = ShelfDropPlanner.acceptance(types: [PasteboardTypes.plainText], originatesInShelf: false)
        let own = ShelfDropPlanner.acceptance(types: [PasteboardTypes.plainText], originatesInShelf: true)

        #expect(acceptance == .accepted)
        #expect(own != .accepted)

        let rig = ShelfRig(rows: [makeShelfRow(1)])
        await rig.openSticky()
        #expect(rig.model.isDropTargeted == false)
        rig.model.setDropTargeted(acceptance == .accepted)
        #expect(rig.model.isDropTargeted == true)
    }

    // OC-6090. Given capture mode Paused and N items, when 3 files from Finder are dropped, then the count is N+1
    // and the top item is a bundle of 3 with source Finder. The existing test never set Paused and started from N=0.
    // Turns red if a drop honours Paused, ends up as three items, or loses the source.
    @Test("OC-6090 with capture Paused, three Finder files make one bundle of 3 and the count N+1")
    func oc6090_pausedFinderDropIsOneBundle() async throws {
        let rig = try await GapRig.make()
        defer { rig.cleanUp() }
        let seeded = try await rig.seed(2)
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        #expect(rig.settings.value(SettingKeys.captureMode) == .paused)
        let urls = try ["a.txt", "b.txt", "c.txt"].map { try rig.file($0) }

        let dropped = try #require(await rig.dropFiles(urls, source: finder, at: 10))

        let rows = try await rig.rows()
        #expect(try await rig.itemCount() == 3)
        #expect(rows.first?.id == dropped)
        #expect(rows.first?.kind == .bundle)
        #expect(rows.first?.memberCount == 3)
        #expect(rows.first?.sourceName == "Finder")
        #expect(Set(rows.map(\.id)) == Set(seeded + [dropped]))
    }

    // OC-6091. Given count N, when the text 'https://example.com/drop' is dropped, then the count is N+1 and the new
    // item's kind is link. The existing test started from an empty store. Turns red if the drop replaces an existing
    // item, or the URL is stored as plain text.
    @Test("OC-6091 a dropped URL makes the count N+1 and is a link, the earlier item survives")
    func oc6091_urlDropAddsOneLink() async throws {
        let rig = try await GapRig.make()
        defer { rig.cleanUp() }
        let seeded = try await rig.seed(1)

        let dropped = try #require(await rig.dropText("https://example.com/drop", at: 10))

        let rows = try await rig.rows()
        #expect(try await rig.itemCount() == 2)
        #expect(rows.first { $0.id == dropped }?.kind == .link)
        #expect(rows.first { $0.id == seeded[0] }?.kind == .text)
    }

    // OC-6093. Given capture mode Curated and count N, when 'curated-drop' is dropped from TextEdit, then the count
    // is N+1 with that text. Turns red if a drop consults the capture mode and discards under Curated.
    @Test("OC-6093 with capture Curated, text dropped from TextEdit is stored and the count is N+1")
    func oc6093_curatedDropIsStored() async throws {
        let rig = try await GapRig.make()
        defer { rig.cleanUp() }
        _ = try await rig.seed(2)
        rig.settings.set(CaptureMode.curated, for: SettingKeys.captureMode)
        #expect(rig.settings.value(SettingKeys.captureMode) == .curated)

        let dropped = try #require(await rig.dropText("curated-drop", source: textEdit, at: 10))

        #expect(try await rig.itemCount() == 3)
        #expect(try await rig.database.content(of: dropped).get().plainText == "curated-drop")
    }

    // OC-6094 (drop half). Given TextEdit on the ignored-apps list and count N, when 'ign-drop' is dragged from
    // TextEdit onto the Shelf, then it is stored (count N+1). Turns red if a drop applies the ignored-apps list.
    // The 'ign-copy' half (a copy in TextEdit is not stored) is ClipboardCapture's and not reachable from
    // FlotsamShelfTests (target deps: FlotsamShelf, FlotsamBase, FlotsamStorage, FlotsamPayload).
    @Test("OC-6094 text dragged from an ignored app is still stored and the count is N+1")
    func oc6094_ignoredAppDropIsStored() async throws {
        let rig = try await GapRig.make()
        defer { rig.cleanUp() }
        _ = try await rig.seed(2)
        rig.settings.set(BundleIdentifierList(["com.apple.TextEdit"]), for: SettingKeys.privacyIgnoredApps)
        #expect(rig.settings.value(SettingKeys.privacyIgnoredApps).identifiers == ["com.apple.TextEdit"])

        let dropped = try #require(await rig.dropText("ign-drop", source: textEdit, at: 10))

        #expect(try await rig.itemCount() == 3)
        #expect(try await rig.database.content(of: dropped).get().plainText == "ign-drop")
    }

    // OC-6105. The dropped card is highlighted for about 600 ms. No test asserted the duration. Turns red if the
    // constant changes (the timer in ShelfPanelController and the flash in ShelfView both read it).
    @Test("OC-6105 the drop highlight lasts 0.6 seconds")
    func oc6105_highlightDurationIsSixHundredMilliseconds() {
        #expect(ShelfLayout.dropHighlightDuration == 0.6)
    }

    // OC-6078. Given cards A and B dragged out and accepted, then each paste count is +1 and the third card is
    // untouched. The planner test checks which cards contribute; nothing checked that one paste per card is counted
    // by storage. Turns red if recordPaste adds anything but 1, or touches another item.
    @Test("OC-6078 an accepted drag of two cards counts one paste each and no paste on the third")
    func oc6078_oneCountedPastePerDraggedCard() async throws {
        let rig = try await GapRig.make()
        defer { rig.cleanUp() }
        let ids = try await rig.seed(3)
        var candidates: [ShelfDragCandidate] = []
        for id in [ids[0], ids[1]] {
            candidates.append(ShelfDragCandidate(itemId: id, content: try await rig.database.content(of: id).get()))
        }
        let plan = try ShelfDragPlanner.plan(candidates, files: LocalFileSystem()).get()
        let before = try await rig.rows().map { ($0.id, $0.pasteCount) }
        #expect(before.map(\.1) == [0, 0, 0])

        for id in plan.draggedItemIds { _ = await rig.database.recordPaste(of: id) }

        let after = try await rig.rows()
        #expect(plan.draggedItemIds == [ids[0], ids[1]])
        #expect(after.first { $0.id == ids[0] }?.pasteCount == 1)
        #expect(after.first { $0.id == ids[1] }?.pasteCount == 1)
        #expect(after.first { $0.id == ids[2] }?.pasteCount == 0)
        #expect(after.count == 3)
    }

    // OC-6079 and OC-6080. The existing planner tests assert the error code only; the oracle's then-clause is the
    // LIB-DAT-001 HUD with the catalogue sentence and no drag. Turns red if the code changes, the wrong sentence is
    // shown, or a drag plan is produced for files that are gone.
    @Test("OC-6079 a bundle whose members are all gone yields no drag and the LIB-DAT-001 HUD text")
    func oc6079_goneBundleShowsTheMovedOrDeletedHUD() async throws {
        let rig = try await GapRig.make()
        defer { rig.cleanUp() }
        let gone = ["gone-a.txt", "gone-b.txt"].map { rig.files.appendingPathComponent($0).path }
        let candidate = ShelfDragCandidate(
            itemId: UUID(), content: ItemContent(
                kind: .bundle, plainText: nil, representations: [],
                members: gone.map { ItemMember(path: $0, bookmark: nil, isDirectory: false) }))

        let result = ShelfDragPlanner.plan([candidate], files: LocalFileSystem())

        guard case .failure(let error) = result else {
            Issue.record("a drag plan was produced for a bundle whose members are all gone")
            return
        }
        #expect(error.code == .libDat001)
        await rig.reporter.report(error, origin: .userInitiated)
        #expect(rig.presenter.huds == ["The original file or folder has moved or been deleted."])
    }

    @Test("OC-6080 a file card whose file was deleted starts no drag and shows the LIB-DAT-001 HUD text")
    func oc6080_goneFileShowsTheMovedOrDeletedHUD() async throws {
        let rig = try await GapRig.make()
        defer { rig.cleanUp() }
        let url = try rig.file("will-be-deleted.txt")
        let candidate = ShelfDragCandidate(
            itemId: UUID(), content: ItemContent(
                kind: .file, plainText: nil, representations: [],
                members: [ItemMember(path: url.path, bookmark: nil, isDirectory: false)]))
        // Boundary: while the file exists the same card plans one item and shows no HUD.
        let present = try ShelfDragPlanner.plan([candidate], files: LocalFileSystem()).get()
        #expect(present.items.count == 1)
        try FileManager.default.removeItem(at: url)

        let result = ShelfDragPlanner.plan([candidate], files: LocalFileSystem())

        guard case .failure(let error) = result else {
            Issue.record("a drag plan was produced for a deleted file")
            return
        }
        #expect(error.code == .libDat001)
        #expect(rig.presenter.huds.isEmpty)
        await rig.reporter.report(error, origin: .userInitiated)
        #expect(rig.presenter.huds == ["The original file or folder has moved or been deleted."])
    }
}
