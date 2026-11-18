import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// FRD-004 8T contract tests, slice Library (oracle .claude/oracle/frd-004-contract.json): the Library-target half of
// OC-4017 4030 4031 4062 4072 4073 4075 4077 4082 4084 4096 4097 4099 4105 4108 4109. These drive the shipping
// LibraryViewModel, LibraryOrganizer, LibraryContextMenu and SettingsLibraryPreferences over a REAL FlotsamDatabase in
// a temp folder (never the real Flotsam data folder, never UserDefaults). What the package cannot reach (the
// OrganizeCoordinator confirm overlays and the hotkey registry live in the App target, which has no test target) is
// listed in FRD004ContractTestsGaps.swift. Expected values are literals; state is read back through a fresh query.
//
// OC-4073: the oracle names the string key as the FRD does, `ui.organize.confirmUngroup` (TASK-467 fixed the stale key).

// MARK: Local doubles (private to this file; Storage's RecordingLogSink is not visible to this test target)

private final class OrganizeRecordingLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { records.append(record) } }
    /// Every record's public and private text, joined, that contains `needle`.
    func lines(containing needle: String) -> [String] {
        lock.withLock { records.map { $0.publicText + " | " + $0.privateText }.filter { $0.contains(needle) } }
    }
}

@MainActor
private final class OrganizeRecordingPresenter: ErrorPresenter {
    private(set) var huds: [String] = []
    private(set) var noticeLists: [[Notice]] = []
    private(set) var fatals = 0
    func showHUD(message: String) { huds.append(message) }
    func noticesChanged(_ notices: [Notice]) { noticeLists.append(notices) }
    func presentFatal(_ error: FlotsamError) { fatals += 1 }
}

private let fileClassifiers = ItemClassifiers(
    editedText: { ItemClassification(kind: .text, contentKey: "edit:" + $0) },
    fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) })

/// The shipping LibraryViewModel and LibraryOrganizer over a real database whose log goes to a recording sink.
@MainActor
private final class OrganizeRig {
    let root: URL
    let epoch = Date()
    let database: FlotsamDatabase
    let ingest: IngestActor
    let prefs = FakePreferences()
    let reported = Harness.Reported()
    let sink: OrganizeRecordingLogSink
    let organizer: LibraryOrganizer
    let model: LibraryViewModel

    static func make() async throws -> OrganizeRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-frd004-lib-\(UUID().uuidString)")
        let sink = OrganizeRecordingLogSink()
        let database = try await FlotsamDatabase.open(folder: root, logSink: sink).get()
        return OrganizeRig(root: root, database: database, sink: sink)
    }

    private init(root: URL, database: FlotsamDatabase, sink: OrganizeRecordingLogSink) {
        self.root = root
        self.database = database
        self.sink = sink
        ingest = IngestActor(database: database, settings: SettingsStore(store: ContractMemoryKV()))
        let reported = reported
        organizer = LibraryOrganizer(store: database, classifiers: fileClassifiers, report: { reported.errors.append($0) })
        model = LibraryViewModel(
            source: database, paster: FakePaster(), host: FakeHost(), preferences: prefs,
            effects: LibraryEffects(
                report: { reported.errors.append($0) }, reveal: { reported.revealed.append($0) },
                openSettings: { reported.settingsOpened += 1 },
                external: { reported.external.append(($0, $1)) }, isAccessibilityTrusted: { true }),
            organizer: organizer)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func add(
        _ kind: ItemKind, key: String, text: String? = nil, members: [IngestMember] = [],
        representations: [PasteboardRepresentation] = [], secondsAgo: Double = 0
    ) async throws -> UUID {
        let candidate = IngestCandidate(
            kind: kind, contentKey: key, plainText: text, representations: representations, members: members,
            source: SourceApp(bundleId: "com.example.notes", name: "Notes"), origin: .pasteboard,
            occurredAt: epoch.addingTimeInterval(-secondsAgo), originalPath: nil)
        return try await ingest.ingest(candidate).get().itemId
    }

    func bundle(_ key: String, memberCount: Int, secondsAgo: Double = 0) async throws -> UUID {
        let members = (1...memberCount).map { IngestMember(path: "/frd004/\(key)/f\($0).txt", bookmark: nil, isDirectory: false) }
        return try await add(.bundle, key: key, members: members, secondsAgo: secondsAgo)
    }

    /// Every item, read fresh from the database, not from the model's loaded page.
    func allRows() async throws -> [ItemRow] {
        var rows: [ItemRow] = []
        var page = 0
        while true {
            let result = try await database.items(matching: LibraryQuery(page: page)).get()
            rows += result.rows
            guard result.hasMore, page < 1_000 else { break }
            page += 1
        }
        return rows
    }

    func open() async {
        await model.open(target: nil)
        await model.settled()
    }

    func tags() async throws -> [SidebarCounts.TagCount] { try await database.sidebarCounts().get().tags }
}

private func itemRow(_ n: Int, kind: ItemKind = .text, pinned: Bool = false, trigger: Bool = false, shortcut: Bool = false) -> ItemRow {
    ItemRow(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, kind: kind,
        lastCopiedAt: Date(timeIntervalSince1970: 1_000_000), pasteCount: 0, primaryLine: "row \(n)", sourceName: "Notes",
        tagNames: [], isPinned: pinned, hasTrigger: trigger, hasShortcut: shortcut, pixelWidth: nil, pixelHeight: nil,
        memberCount: 0, byteSize: 0)
}

/// The organize titles a context menu carries for one item kind, as catalogue keys in menu order.
private func organizeKeys(_ kind: ItemKind, pinUnpins: Bool = false, singleTarget: Bool = true) -> [String] {
    LibraryContextMenu.entries(kind: kind, pinUnpins: pinUnpins, singleTarget: singleTarget).compactMap { entry in
        if case .item(let titleKey, _, _) = entry, titleKey.hasPrefix("ui.organize.") { return titleKey }
        return nil
    }
}

@MainActor
@Suite struct FRD004ContractTestsLibrary {
    // MARK: OC-4017 colours

    @Test("OC-4017 given the tag colour model, when its cases and names are read, then exactly eight colours in order, no custom")
    func oc4017EightColours() async throws {
        // Red if: a colour is added, removed or reordered in TagColor, or a colour name string changes.
        // given the shipped colour model; when listing it; then eight literal values, in palette order
        #expect(TagColor.allCases.map(\.rawValue) == ["red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"])
        let names = ["red": "Red", "orange": "Orange", "yellow": "Yellow", "green": "Green", "blue": "Blue", "purple": "Purple", "pink": "Pink", "gray": "Gray"]
        for color in TagColor.allCases {
            #expect(FlotsamStrings.text(forKey: "ui.organize.color" + color.rawValue.prefix(1).uppercased() + color.rawValue.dropFirst()) == names[color.rawValue])
        }
        // A stored value outside the eight (a custom hex) is not a ninth colour: it reads back as the default grey.
        #expect(TagColor(stored: "#123456") == .gray)
        #expect(TagColor.allCases.count == 8)
    }

    @Test("OC-4017 given a tag, when recoloured to each of the eight colours, then the stored colour reads back each time")
    func oc4017RecolourRoundTrip() async throws {
        // Red if: recolorTag stores the wrong colour or fails for any one of the eight.
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        let tagId = try await rig.database.createTag(name: "paint", color: .red).get()
        for color in ["orange", "yellow", "green", "blue", "purple", "pink", "gray", "red"] {
            // when recolouring; then a fresh sidebar read shows exactly that colour on exactly that tag
            let changed = await rig.model.recolorTag(tagId, to: TagColor(stored: color))
            #expect(changed)
            let tags = try await rig.tags()
            #expect(tags.count == 1)
            #expect(tags.first?.name == "paint")
            #expect(tags.first?.color == color)
        }
    }

    // MARK: OC-4030 / OC-4031 delete-tag confirmation

    @Test("OC-4030 given a tag on 5 of 6 items, when the delete is asked, then the sidebar count is 5 and the prompt reads 5 items")
    func oc4030PromptCountsFiveItems() async throws {
        // Red if: the count the prompt shows stops coming from the tag's real item count, or the prompt template changes.
        // The cancel path (the tag and its items unchanged) is the OrganizeCoordinator overlay: see the Gaps file.
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        var ids: [UUID] = []
        for n in 1...6 { ids.append(try await rig.add(.text, key: "k\(n)", text: "note \(n)", secondsAgo: Double(n))) }
        let tagId = try await rig.database.createTagAndApply(name: "T", to: Array(ids.prefix(5))).get()
        // when reading what the prompt is built from; then 5 carry the tag and the prompt says so
        let tags = try await rig.tags()
        #expect(tags.map(\.name) == ["T"])
        #expect(tags.first?.count == 5)
        #expect(tags.first?.id == tagId)
        #expect(LibraryText.confirmDeleteTag(name: "T", itemCount: 5) == "Remove tag 'T' from 5 items?")
        // nothing was deleted by asking
        #expect(try await rig.allRows().count == 6)
    }

    @Test("OC-4031 given a tag on 0 items, when it is deleted, then it is gone, 0 items were carrying it and the item count is unchanged")
    func oc4031EmptyTagDeletesWithoutTouchingItems() async throws {
        // Red if: deleting an empty tag removes an item, fails, or leaves the tag listed.
        // The no-prompt decision is LibraryOrganizer.deleteTagNeedsConfirmation (the App calls it): tested just below.
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        for n in 1...3 { try await rig.add(.text, key: "k\(n)", text: "plain \(n)", secondsAgo: Double(n)) }
        let tagId = try await rig.database.createTag(name: "empty").get()
        let before = try await rig.tags()
        #expect(before.map(\.name) == ["empty"])
        #expect(before.first?.count == 0)
        await rig.open()
        // when deleting it through the model; then 0 carried it, the tag is gone, all 3 items remain
        let removed = await rig.model.deleteTag(tagId)
        #expect(removed == 0)
        #expect(try await rig.tags().isEmpty)
        #expect(try await rig.allRows().count == 3)
        #expect(rig.reported.errors.isEmpty)
    }

    @Test("OC-4031 given a tag on 0 items, when the delete is asked, then no confirmation is needed; on 1 or more items it is")
    func oc4031NoConfirmationAtZeroItems() {
        // Red if: deleteTagNeedsConfirmation asks for an empty tag, or stops asking once the tag is on an item.
        // The App's OrganizeCoordinator.deleteTag calls this one function, so this is the decision the user sees.
        #expect(LibraryOrganizer.deleteTagNeedsConfirmation(itemCount: 0) == false)
        #expect(LibraryOrganizer.deleteTagNeedsConfirmation(itemCount: 1) == true)
        #expect(LibraryOrganizer.deleteTagNeedsConfirmation(itemCount: 5) == true)
    }

    // MARK: OC-4062 delete of a plain item

    @Test("OC-4062 given a plain unpinned item, when Command-Delete is pressed, then it needs no confirmation and a confirmed delete removes exactly it")
    func oc4062PlainItemDeletesWithoutConfirmation() async throws {
        // Red if: the key map stops sending delete, or a plain item starts asking for confirmation, or the delete
        // removes the wrong row or leaves the item searchable.
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        let doomed = try await rig.add(.text, key: "a", text: "quokka plain", secondsAgo: 1)
        let keepB = try await rig.add(.text, key: "b", text: "bravo plain", secondsAgo: 2)
        let keepC = try await rig.add(.text, key: "c", text: "charlie plain", secondsAgo: 3)
        await rig.open()
        rig.model.select(id: doomed)
        // control: the search finds it before the delete, so the later 0 is meaningful
        #expect(try await rig.database.items(matching: LibraryQuery(text: "quokka")).get().rows.map(\.id) == [doomed])
        // when the delete chord is pressed; then the Library asks the owner of delete for exactly this item
        #expect(rig.model.handle(LibraryKeyStroke(.delete, .command)))
        #expect(rig.reported.external.count == 1)
        #expect(rig.reported.external.first?.0 == .delete)
        #expect(rig.reported.external.first?.1 == [doomed])
        // and the rule says no dialog for a plain single unpinned item with no hotkey or trigger
        #expect(LibraryOrganizer.deleteNeedsConfirmation(rig.model.selectedRows) == false)
        // when the owner deletes it; then N-1 remain (fresh read), the target is gone, the survivors are intact
        let removed = await rig.model.deleteSelected(expecting: [doomed])
        #expect(removed == [doomed])
        let after = try await rig.allRows()
        #expect(after.count == 2)
        #expect(Set(after.map(\.id)) == [keepB, keepC])
        #expect(try await rig.database.items(matching: LibraryQuery(text: "quokka")).get().rows.isEmpty)
    }

    @Test("OC-4062 given a pinned, triggered, hotkeyed or multiple selection, when delete is asked, then confirmation is required")
    func oc4062NegativeCasesNeedConfirmation() {
        // Red if: deleteNeedsConfirmation ignores pin, trigger, hotkey or the multi-item case.
        // given each non-plain shape; when asking; then true. The plain single row is the control, false.
        #expect(LibraryOrganizer.deleteNeedsConfirmation([itemRow(1)]) == false)
        #expect(LibraryOrganizer.deleteNeedsConfirmation([itemRow(1, pinned: true)]) == true)
        #expect(LibraryOrganizer.deleteNeedsConfirmation([itemRow(1, trigger: true)]) == true)
        #expect(LibraryOrganizer.deleteNeedsConfirmation([itemRow(1, shortcut: true)]) == true)
        #expect(LibraryOrganizer.deleteNeedsConfirmation([itemRow(1), itemRow(2)]) == true)
        #expect(LibraryOrganizer.deleteNeedsConfirmation([]) == false)
    }

    // MARK: OC-4072 / OC-4073 Ungroup availability and confirmation

    @Test("OC-4072 given file, two bundles, bundle plus text, one bundle, when Ungroup availability is asked, then only one bundle is available")
    func oc4072UngroupAvailability() {
        // Red if: canUngroup accepts a non-bundle or more than one row, or rejects a lone bundle.
        // given each selection shape; then available only for exactly one bundle
        #expect(LibraryOrganizer.canUngroup([itemRow(1, kind: .file)]) == false)
        #expect(LibraryOrganizer.canUngroup([itemRow(1, kind: .bundle), itemRow(2, kind: .bundle)]) == false)
        #expect(LibraryOrganizer.canUngroup([itemRow(1, kind: .bundle), itemRow(2, kind: .text)]) == false)
        #expect(LibraryOrganizer.canUngroup([]) == false)
        #expect(LibraryOrganizer.canUngroup([itemRow(1, kind: .bundle)]) == true)
    }

    @Test("OC-4072 given a bundle, a file and a multi-selection menu, when entries are built, then Ungroup is only on the single bundle menu")
    func oc4072UngroupMenuEntry() {
        // Red if: the context menu offers Ungroup for a non-bundle or for a multi-selection, or drops it for a lone bundle.
        // given the three menu shapes; then the Ungroup key appears in exactly one of them
        #expect(organizeKeys(.bundle, singleTarget: true).contains("ui.organize.menuUngroup"))
        #expect(!organizeKeys(.file, singleTarget: true).contains("ui.organize.menuUngroup"))
        #expect(!organizeKeys(.bundle, singleTarget: false).contains("ui.organize.menuUngroup"))
        for kind in ItemKind.allCases where kind != .bundle {
            #expect(!organizeKeys(kind, singleTarget: true).contains("ui.organize.menuUngroup"))
        }
    }

    @Test("OC-4073 given a bundle with note, pin, trigger or hotkey, when Ungroup is asked, then it asks first; a plain bundle does not")
    func oc4073UngroupConfirmationRule() {
        // Red if: ungroupNeedsConfirmation drops the note, pin, trigger or hotkey term, or starts asking for a plain bundle.
        let bundle = itemRow(1, kind: .bundle)
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(bundle, hasNote: false) == false)
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(bundle, hasNote: true) == true)
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(itemRow(1, kind: .bundle, pinned: true), hasNote: false) == true)
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(itemRow(1, kind: .bundle, trigger: true), hasNote: false) == true)
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(itemRow(1, kind: .bundle, shortcut: true), hasNote: false) == true)
        #expect(LibraryText.string("ui.organize.confirmUngroup")
            == "Ungroup this bundle? Its note, pin, trigger and hotkey are not carried over to the new items.")
    }

    @Test("OC-4073 given the FRD's string key, when the catalogue is asked for it, then it resolves to the ungroup warning")
    func oc4073ConfirmationKeyIsTheFRDKey() {
        // Red if: the FRD key (FR-004-11, ui.organize.confirmUngroup) loses its copy or LibraryText stops naming it.
        #expect(LibraryText.string(LibraryText.confirmUngroup).hasPrefix("Ungroup this bundle?"))
        #expect(LibraryText.confirmUngroup == "ui.organize.confirmUngroup")
    }

    @Test("OC-4073 given a real 4-file bundle with a tag, a note and a pin, when its row and note are read, then Ungroup asks first")
    func oc4073RealBundleAsksFirst() async throws {
        // Red if: the pin or the note stops reaching the confirmation decision (row.isPinned from storage, note(of:)).
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        let id = try await rig.bundle("b4", memberCount: 4)
        let plain = try await rig.bundle("plain", memberCount: 2, secondsAgo: 5)
        _ = await rig.organizer.createTag(name: "x", applyingTo: [id])
        #expect(await rig.organizer.setNote("keep this", for: id))
        #expect(await rig.organizer.togglePin([id]) == true)
        await rig.open()
        // when reading the row and note through the shipping paths; then the rule says ask, for the decorated one only
        let decorated = try #require(rig.model.loadedRows.first { $0.id == id })
        let undecorated = try #require(rig.model.loadedRows.first { $0.id == plain })
        #expect(decorated.memberCount == 4)
        #expect(decorated.isPinned)
        #expect(decorated.tagNames == ["x"])
        let note = await rig.organizer.note(of: id)
        #expect(note == "keep this")
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(decorated, hasNote: note != nil) == true)
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(undecorated, hasNote: await rig.organizer.note(of: plain) != nil) == false)
    }

    // MARK: OC-4075 / OC-4077 Ungroup guard

    @Test("OC-4075 given a bundle with a note, when an Ungroup confirmed for another bundle arrives, then nothing changes; the confirmed one ungroups")
    func oc4075StaleConfirmationChangesNothing() async throws {
        // Red if: ungroupSelected ignores `expecting` and ungroups whatever is selected, losing its note and members.
        // The cancel button itself is the OrganizeCoordinator overlay: see the Gaps file.
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        let id = try await rig.bundle("noted", memberCount: 2)
        #expect(await rig.organizer.setNote("remember", for: id))
        await rig.open()
        rig.model.select(id: id)
        let beforeCount = try await rig.allRows().count
        // when the confirmation names a different bundle; then no ungroup happens
        let stale = UUID(uuidString: "00000000-0000-0000-0000-00000000dead")!
        #expect(await rig.model.ungroupSelected(expecting: stale) == nil)
        let rows = try await rig.allRows()
        #expect(rows.count == beforeCount)
        #expect(rows.map(\.id) == [id])
        #expect(rows.first?.kind == .bundle)
        #expect(rows.first?.memberCount == 2)
        #expect(await rig.organizer.note(of: id) == "remember")
        #expect(rig.reported.errors.isEmpty)
        // control: confirming the right bundle ungroups it into its 2 members, so the guard is what stopped the stale one
        let created = try #require(await rig.model.ungroupSelected(expecting: id))
        #expect(created.count == 2)
        let after = try await rig.allRows()
        #expect(after.count == 2)
        #expect(!after.map(\.id).contains(id))
    }

    @Test("OC-4077 given a bundle with a hotkey, when Ungroup is asked, then it asks first; the hotkey going dead is the registry, in the Gaps file")
    func oc4077HotkeyBundleAsksFirst() {
        // Red if: a bundle carrying a hotkey stops asking before Ungroup (the hotkey would die without warning).
        // The storage half (no badge, hotkey cleared) is FRD004ContractTestsDeleteUngroupSort's OC-4077 test.
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(itemRow(1, kind: .bundle, shortcut: true), hasNote: false) == true)
        #expect(LibraryOrganizer.ungroupNeedsConfirmation(itemRow(1, kind: .bundle), hasNote: false) == false)
    }

    // MARK: OC-4082 / OC-4084 filters

    @Test("OC-4082 given tag T on a link and a text, and an untagged link, when T then Links is chosen, then Links replaces T and shows both links")
    func oc4082KindFilterReplacesTagFilter() async throws {
        // Red if: choosing a kind keeps the tag filter (the untagged link would be missing) or drops the kind.
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        let taggedLink = try await rig.add(.link, key: "l1", text: "https://one.example", secondsAgo: 1)
        let taggedText = try await rig.add(.text, key: "t1", text: "tagged text", secondsAgo: 2)
        let plainLink = try await rig.add(.link, key: "l2", text: "https://two.example", secondsAgo: 3)
        let tagId = try #require(await rig.organizer.createTag(name: "T", applyingTo: [taggedLink, taggedText]))
        await rig.open()
        // when choosing the tag; then exactly its two items
        rig.model.select(filter: .tag(tagId))
        await rig.model.settled()
        #expect(rig.model.loadedRows.count == 2)
        #expect(Set(rig.model.loadedRows.map(\.id)) == [taggedLink, taggedText])
        // when choosing Links; then the tag is no longer applied: both links, the text is gone
        rig.model.select(filter: .kind(.link))
        await rig.model.settled()
        #expect(rig.model.filter == .kind(.link))
        #expect(rig.model.loadedRows.count == 2)
        #expect(Set(rig.model.loadedRows.map(\.id)) == [taggedLink, plainLink])
        #expect(!rig.model.loadedRows.map(\.id).contains(taggedText))
    }

    @Test("OC-4084 given tag T chosen with query abc, when All is chosen, then the query is still abc and all abc items list")
    func oc4084AllKeepsQuery() async throws {
        // Red if: choosing All clears the search text, or keeps the tag restriction on the results.
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        let tagged = try await rig.add(.text, key: "a", text: "abc tagged", secondsAgo: 1)
        let untagged = try await rig.add(.text, key: "b", text: "abc untagged", secondsAgo: 2)
        let other = try await rig.add(.text, key: "c", text: "zzz tagged", secondsAgo: 3)
        let tagId = try #require(await rig.organizer.createTag(name: "T", applyingTo: [tagged, other]))
        await rig.open()
        rig.model.setSearchText("abc")
        await rig.model.settled()
        rig.model.select(filter: .tag(tagId))
        await rig.model.settled()
        // control: tag plus query narrows to the one item that has both
        #expect(rig.model.loadedRows.map(\.id) == [tagged])
        // when All is chosen; then the query text stays and every abc item lists, tag or not, and zzz does not
        rig.model.select(filter: .all)
        await rig.model.settled()
        #expect(rig.model.searchText == "abc")
        #expect(rig.model.filter == .all)
        #expect(rig.model.loadedRows.count == 2)
        #expect(Set(rig.model.loadedRows.map(\.id)) == [tagged, untagged])
    }

    // MARK: OC-4096 / OC-4097 sort persistence

    private func makeModel(kv: ContractMemoryKV) -> (model: LibraryViewModel, source: FakeSource) {
        let source = FakeSource(rows: Harness.rows(3))
        let model = LibraryViewModel(
            source: source, paster: FakePaster(), host: FakeHost(),
            preferences: SettingsLibraryPreferences(settings: SettingsStore(store: kv)),
            effects: LibraryEffects())
        return (model, source)
    }

    @Test("OC-4096 given each of the four sorts chosen, when the app relaunches over the same store, then that sort is still active")
    func oc4096SortSurvivesRelaunch() async throws {
        // Red if: the sort choice is not written through the settings store, or not read back at open.
        let expected: [(name: String, raw: String)] = [("Recent", "recent"), ("Oldest", "oldest"), ("Most Used", "mostUsed"), ("A to Z", "alphabetical")]
        for target in expected {
            let kv = ContractMemoryKV()
            let first = makeModel(kv: kv)
            await first.model.open(target: nil)
            await first.model.settled()
            var cycles = 0
            while first.model.footer().sortName != target.name, cycles < 4 {
                first.model.cycleSort()
                await first.model.settled()
                cycles += 1
            }
            #expect(first.model.footer().sortName == target.name)
            // when relaunching: a new settings store, preferences and model over the same persisted values
            let second = makeModel(kv: kv)
            await second.model.open(target: nil)
            await second.model.settled()
            #expect(second.model.footer().sortName == target.name)
            #expect(second.source.queries.last?.sort.rawValue == target.raw)
        }
    }

    @Test("OC-4096 given a stored sort value that is not one of the four, when the Library opens, then it falls back to Recent")
    func oc4096UnknownStoredSortFallsBack() async throws {
        // Red if: an unreadable stored sort crashes or sticks instead of falling back to the default.
        let kv = ContractMemoryKV()
        kv.setString("sideways", forKey: "library.sort")
        let run = makeModel(kv: kv)
        await run.model.open(target: nil)
        await run.model.settled()
        #expect(run.model.footer().sortName == "Recent")
        #expect(run.source.queries.last?.sort.rawValue == "recent")
    }

    @Test("OC-4097 given a fresh install, when the Library opens, then the sort is Recent, shown and queried")
    func oc4097FreshInstallIsRecent() async throws {
        // Red if: the default sort changes from Recent, in the footer or in the query the storage receives.
        let run = makeModel(kv: ContractMemoryKV())
        await run.model.open(target: nil)
        await run.model.settled()
        #expect(run.model.footer().sortName == "Recent")
        #expect(run.source.queries.last?.sort.rawValue == "recent")
        #expect(run.source.queries.isEmpty == false)
    }

    // MARK: OC-4105 menu content

    @Test("OC-4105 given every item kind, when a single-item menu is built, then its organize entries are exactly the FRD-004 set")
    func oc4105SingleItemMenuContent() {
        // Red if: an organize entry is added or removed, appears for the wrong kind, or the Pin/Unpin swap breaks.
        let textual: [ItemKind] = [.text, .richText, .link, .color, .phone, .email]
        for kind in textual {
            #expect(organizeKeys(kind) == ["ui.organize.menuPin", "ui.organize.menuTags", "ui.organize.menuNote", "ui.organize.menuEdit", "ui.organize.menuDelete"])
            #expect(organizeKeys(kind, pinUnpins: true) == ["ui.organize.menuUnpin", "ui.organize.menuTags", "ui.organize.menuNote", "ui.organize.menuEdit", "ui.organize.menuDelete"])
        }
        let nonEditable: [ItemKind] = [.image, .screenshot, .file, .folder]
        for kind in nonEditable {
            #expect(organizeKeys(kind) == ["ui.organize.menuPin", "ui.organize.menuTags", "ui.organize.menuNote", "ui.organize.menuDelete"])
        }
        #expect(organizeKeys(.bundle) == ["ui.organize.menuPin", "ui.organize.menuTags", "ui.organize.menuNote", "ui.organize.menuUngroup", "ui.organize.menuDelete"])
        // control against a vacuous pass: the loops above covered all eleven kinds
        #expect(textual.count + nonEditable.count + 1 == 11)
        #expect(ItemKind.allCases.count == 11)
    }

    @Test("OC-4105 given every kind and both targets, when menu titles are resolved, then none reads Group, Rename, Undo or Move to Trash")
    func oc4105NoForbiddenActions() {
        // Red if: a Group, Rename, Undo or Move to Trash entry is added to the item context menu.
        var seenTitles = Set<String>()
        for kind in ItemKind.allCases {
            for single in [true, false] {
                for entry in LibraryContextMenu.entries(kind: kind, pinUnpins: false, singleTarget: single) {
                    guard case .item(let key, _, _) = entry else { continue }
                    let title = LibraryText.string(key)
                    seenTitles.insert(title)
                    for banned in ["Group", "Rename", "Undo", "Move to Trash"] {
                        #expect(!title.hasPrefix(banned), "\(banned) appeared as \(title)")
                    }
                }
            }
        }
        // control: the scan did see real titles, including Ungroup, which is allowed and contains 'group'
        #expect(seenTitles.contains("Ungroup"))
        #expect(seenTitles.contains("Delete"))
        #expect(seenTitles.contains("Pin"))
        #expect(seenTitles.count >= 10)
    }

    // MARK: OC-4108 no Group action

    @Test("OC-4108 given the shipped surface, when it is searched for Group, then no action, error code or text for it exists")
    func oc4108NoGroupSurface() throws {
        // Red if: a Group menu entry, an ORG-VAL-004 error code or its message is (re)introduced.
        for kind in ItemKind.allCases {
            for single in [true, false] {
                for key in organizeKeys(kind, singleTarget: single) {
                    #expect(key == "ui.organize.menuUngroup" || !key.lowercased().contains("group"))
                }
            }
        }
        #expect(ErrorCode(rawValue: "ORG-VAL-004") == nil)
        #expect(!ErrorCode.allCases.map(\.rawValue).contains("ORG-VAL-004"))
        let catalogue = try FlotsamCatalogue.englishStrings().get()
        #expect(catalogue.count > 100)
        #expect(catalogue.keys.filter { $0.contains("ORG-VAL-004") }.isEmpty)
        #expect(catalogue.values.filter { $0.contains("Select at least two files, folders or images to group.") }.isEmpty)
        #expect(catalogue.values.filter { $0.contains("ORG-VAL-004") }.isEmpty)
    }

    @Test("OC-4108 given 2 and then 1 file, folder and image selected, when every organize action runs, then ORG-VAL-004 is never raised or logged")
    func oc4108NothingRaisedOnMultiSelect() async throws {
        // Red if: any organize path starts rejecting a multi-file or multi-image selection with ORG-VAL-004.
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        let png = [PasteboardRepresentation(uti: "public.png", data: ContractPNG.make(width: 40, height: 30))]
        let fileA = try await rig.add(.file, key: "fa", members: [IngestMember(path: "/frd004/a.txt", bookmark: nil, isDirectory: false)], secondsAgo: 1)
        let folder = try await rig.add(.folder, key: "fo", members: [IngestMember(path: "/frd004/dir", bookmark: nil, isDirectory: true)], secondsAgo: 2)
        let image = try await rig.add(.image, key: "im", representations: png, secondsAgo: 3)
        await rig.open()
        for selection in [[fileA, folder, image], [fileA, folder], [image], [folder], [fileA]] {
            rig.model.select(id: selection[0])
            for id in selection.dropFirst() { rig.model.toggle(id: id) }
            #expect(rig.model.selection == Set(selection))
            // when pinning, tagging and noting the selection; then every call succeeds with no error
            #expect(await rig.model.togglePinSelected() != nil)
            #expect(await rig.model.createTagOnSelection(name: "g\(selection.count)\(selection[0].uuidString.prefix(4))") != nil)
            #expect(await rig.model.saveNote("n", for: selection[0]))
        }
        #expect(rig.reported.errors.isEmpty)
        // control: the capture path is live; a real rejection IS recorded, with the code it should have
        #expect(await rig.model.renameTag(-1, to: "") == false)
        #expect(rig.reported.errors.map(\.code.rawValue) == ["ORG-VAL-001"])
        // and every raised error, run through the real reporter, produces no ORG-VAL-004 log line
        let presenter = OrganizeRecordingPresenter()
        let reporter = ErrorReporter(presenter: presenter, sink: rig.sink)
        for error in rig.reported.errors { await reporter.report(error, origin: .inline) }
        #expect(rig.sink.lines(containing: "ORG-VAL-004").isEmpty)
        #expect(rig.sink.lines(containing: "ORG-VAL-001").count == 1)
    }

    // MARK: OC-4109 no Rename of items, tag-name limits

    @Test("OC-4109 given tag alpha, when it is renamed to 81 characters or to empty, then ORG-VAL-001 is raised once each and the name stays")
    func oc4109TagRenameRejected() async throws {
        // Red if: a bad tag name is accepted, raises another code (ORG-VAL-005), or changes the stored name.
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        let tagId = try await rig.database.createTag(name: "alpha").get()
        let eightyOne = String(repeating: "a", count: 81)
        for bad in [eightyOne, ""] {
            let before = rig.reported.errors.count
            // when renaming; then rejected, exactly one new ORG-VAL-001, and a fresh read still shows alpha
            #expect(await rig.model.renameTag(tagId, to: bad) == false)
            #expect(rig.reported.errors.count == before + 1)
            #expect(rig.reported.errors.last?.code.rawValue == "ORG-VAL-001")
            #expect(try await rig.tags().map(\.name) == ["alpha"])
        }
        #expect(FlotsamStrings.text(forKey: "error.ORG-VAL-001") == "Tag names must be 1 to 32 characters and unique.")
        // control: a valid rename IS accepted, so the rejections above came from the name and not from a dead path
        #expect(await rig.model.renameTag(tagId, to: "beta") == true)
        #expect(try await rig.tags().map(\.name) == ["beta"])
    }

    @Test("OC-4109 given a rejected tag name, when it is reported inline, then it logs ORG-VAL-001 only and shows no HUD or Notice")
    func oc4109InlineErrorLoggedNeverSurfaced() async throws {
        // Red if: a rejected tag name raises ORG-VAL-005 or surfaces as a HUD or Notice instead of in place.
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        let tagId = try await rig.database.createTag(name: "alpha").get()
        #expect(await rig.model.renameTag(tagId, to: "") == false)
        let error = try #require(rig.reported.errors.first)
        let presenter = OrganizeRecordingPresenter()
        let sink = OrganizeRecordingLogSink()
        let reporter = ErrorReporter(presenter: presenter, sink: sink)
        // when the Library's reported error goes through the real reporter, inline as the FRD requires
        await reporter.report(error, origin: .inline)
        // then one ORG-VAL-001 line, no ORG-VAL-005 line, no HUD and no Notice
        #expect(sink.lines(containing: "ORG-VAL-001").count == 1)
        #expect(sink.lines(containing: "ORG-VAL-005").isEmpty)
        #expect(presenter.huds.isEmpty)
        #expect(presenter.noticeLists.allSatisfy { $0.isEmpty })
        #expect(presenter.fatals == 0)
    }

    @Test("OC-4109 given the shipped surface, when it is searched for item rename and the retired code, then none exists")
    func oc4109NoItemRenameNoRetiredCode() throws {
        // Red if: an item/bundle Rename action, the ORG-VAL-005 code or its message is (re)introduced.
        #expect(ErrorCode(rawValue: "ORG-VAL-005") == nil)
        #expect(!ErrorCode.allCases.map(\.rawValue).contains("ORG-VAL-005"))
        let catalogue = try FlotsamCatalogue.englishStrings().get()
        #expect(catalogue.keys.filter { $0.contains("ORG-VAL-005") }.isEmpty)
        #expect(catalogue.values.filter { $0.contains("Names must be 1 to 80 characters.") }.isEmpty)
        for kind in ItemKind.allCases {
            for single in [true, false] {
                #expect(!organizeKeys(kind, singleTarget: single).contains("ui.organize.menuRename"))
            }
        }
        // control: the Rename string exists for the sidebar TAG menu, so the item-menu absence above is meaningful
        #expect(catalogue["ui.organize.menuRename"] == "Rename")
    }

    // MARK: OC-4099 counts and footer follow every organize command

    @Test("OC-4099 given 3 texts, a link and a 2-member bundle, when an item is pinned, tagged, edited, ungrouped, deleted and a new capture is refreshed in, then after each command the sidebar counts and footer count text are the new literals and the footer equals the rows listed")
    func oc4099SidebarAndFooterFollowEachCommand() async throws {
        // Red if: any organize command leaves the sidebar counts (all, pinned, kinds, tags) or the footer count text at their
        // old value, or the footer count text stops equalling the rows under the active filter. The 200 ms bound is a
        // scheduler matter the package cannot clock reliably (listed in FRD004ContractTestsGaps.swift); what is checked
        // here is that each command's own await already leaves the new numbers in place, with no second refresh.
        let rig = try await OrganizeRig.make()
        defer { rig.cleanUp() }
        let t1 = try await rig.add(.text, key: "t1", text: "one", secondsAgo: 5)
        let t2 = try await rig.add(.text, key: "t2", text: "two", secondsAgo: 4)
        _ = try await rig.add(.text, key: "t3", text: "three", secondsAgo: 3)
        let link = try await rig.add(.link, key: "l1", text: "https://one.example", secondsAgo: 2)
        let bundle = try await rig.bundle("b1", memberCount: 2, secondsAgo: 1)
        await rig.open()
        let start = try #require(rig.model.sidebar)
        #expect(start.all == 5 && start.pinned == 0 && start.tags.isEmpty)
        #expect(start.kinds == [.text: 3, .link: 1, .bundle: 1])
        #expect(rig.model.footer().countText == "5 items" && rig.model.loadedRows.count == 5)

        // pin t1
        rig.model.select(id: t1)
        #expect(await rig.model.togglePinSelected() == true)
        #expect(rig.model.sidebar?.pinned == 1 && rig.model.sidebar?.all == 5)
        #expect(rig.model.footer().countText == "5 items")

        // tag t1 with a new tag
        let tag = try #require(await rig.model.createTagOnSelection(name: "x"))
        #expect(rig.model.sidebar?.tags.map(\.name) == ["x"] && rig.model.sidebar?.tags.map(\.count) == [1])

        // edit the link into plain text: Links disappears from the sidebar and Text gains one
        rig.model.select(id: link)
        #expect(await rig.model.saveEdit(text: "plain words") == .text)
        #expect(rig.model.sidebar?.kinds == [.text: 4, .bundle: 1])
        #expect(rig.model.footer().countText == "5 items")

        // ungroup the bundle: one bundle becomes two files
        rig.model.select(id: bundle)
        #expect(await rig.model.ungroupSelected() != nil)
        #expect(rig.model.sidebar?.all == 6 && rig.model.sidebar?.kinds[.bundle] == nil && rig.model.sidebar?.kinds[.file] == 2)
        // the two files it made are selected, so the footer shows the selection, while the list total is the new 6
        #expect(rig.model.footer().countText == "2 selected" && rig.model.totalCount == 6 && rig.model.loadedRows.count == 6)

        // delete t2
        rig.model.select(id: t2)
        #expect(await rig.model.deleteSelected() == [t2])
        #expect(rig.model.sidebar?.all == 5 && rig.model.sidebar?.kinds[.text] == 3)
        #expect(rig.model.footer().countText == "5 items" && rig.model.loadedRows.count == 5)
        #expect(!rig.model.loadedRows.map(\.id).contains(t2))

        // a new capture arrives (the model does not subscribe to storage; the App calls refresh, see the Gaps file)
        _ = try await rig.add(.text, key: "t4", text: "four", secondsAgo: 0)
        await rig.model.refresh()
        #expect(rig.model.sidebar?.all == 6 && rig.model.footer().countText == "6 items" && rig.model.loadedRows.count == 6)

        // under the tag filter the footer equals the rows under that filter, and deleting that row empties both
        rig.model.select(filter: .tag(tag))
        await rig.model.settled()
        #expect(rig.model.loadedRows.map(\.id) == [t1])
        #expect(rig.model.footer().countText == "1 item")
        #expect(await rig.model.deleteSelected() == [t1])
        #expect(rig.model.footer().countText == "0 items" && rig.model.loadedRows.isEmpty)
        #expect(rig.model.sidebar?.all == 5 && rig.model.sidebar?.pinned == 0)
        #expect(rig.model.sidebar?.tags.map(\.count) == [0])
        // read fresh: the database agrees with what the model shows
        #expect(try await rig.allRows().count == 5)
    }
}
