import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// FRD-003 8T, contract OC-3008 to OC-3028 (layout, persistence, open state, row presentation, navigation). The
// expected side of every assertion is a literal from .claude/oracle/frd-003-contract.json (blind); no production
// symbol computes it.

@MainActor
@Suite struct Frd003ContractPanelTests {
    private let target = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

    private func opened(
        _ rows: [ItemRow], counts: SidebarCounts? = nil, mode: LibraryViewMode = .list
    ) async -> Harness {
        let harness = Harness(rows: rows, counts: counts)
        harness.prefs.viewMode = mode
        await harness.model.open(target: target)
        return harness
    }

    private func key(_ input: LibraryKeyInput, _ modifiers: ChordModifiers = []) -> LibraryKeyStroke {
        LibraryKeyStroke(input, modifiers)
    }

    private func selectedIndex(_ h: Harness, in rows: [ItemRow]) -> Int? {
        guard h.model.selection.count == 1, let id = h.model.selection.first else { return nil }
        return rows.firstIndex { $0.id == id }
    }

    // MARK: Placement and size (FR-003-03)

    // OC-3008. Mutation: centre on the main screen instead of the given frame, or use half height instead of a third.
    @Test("OC-3008 panel opens centred on the pointer screen, top edge one third down")
    func oc3008_placement() {
        // given: display 2, 1920 x 1055 visible, to the right of display 1 (origin x 1440), default size
        let visible = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        // when: the panel is placed
        let frame = LibraryLayout.frame(in: visible, size: PanelSize(width: 760, height: 480))
        // then: centre x 2400, top edge 1055 - 351.67 = 703.33, size untouched
        #expect(abs(frame.midX - 2400) <= 1)
        #expect(abs(frame.maxY - 703.33) <= 1)
        #expect(frame.width == 760)
        #expect(frame.height == 480)
        // and: a screen at a negative origin (display left of the primary) is honoured, not forced to 0,0
        let left = LibraryLayout.frame(in: CGRect(x: -1280, y: 100, width: 1280, height: 800), size: PanelSize(width: 760, height: 480))
        #expect(abs(left.midX - (-640)) <= 1)
        #expect(abs(left.maxY - 633.33) <= 1)
    }

    // OC-3009. Mutation: change the shipped default size.
    @Test("OC-3009 a fresh install opens the panel at 760 x 480")
    func oc3009_defaultSize() {
        // given: a fresh install (empty settings store)
        let prefs = SettingsLibraryPreferences(settings: SettingsStore(store: ContractMemoryKV()))
        // when: the remembered size is read for the first open
        let frame = LibraryLayout.frame(in: CGRect(x: 0, y: 0, width: 1920, height: 1080), size: prefs.panelSize)
        // then: 760 x 480
        #expect(frame.width == 760)
        #expect(frame.height == 480)
    }

    // OC-3010. Mutation: drop the clamp, or clamp only one axis, or move the minimum.
    @Test("OC-3010 dragging to 400 x 300 stops at 560 x 360", arguments: [
        (400.0, 300.0, 560.0, 360.0), (560.0, 360.0, 560.0, 360.0), (561.0, 361.0, 561.0, 361.0),
        (400.0, 700.0, 560.0, 700.0), (900.0, 200.0, 900.0, 360.0),
    ])
    func oc3010_minimum(w: Double, h: Double, expectedW: Double, expectedH: Double) {
        // given/when: a drag to w x h is clamped, then placed
        let clamped = LibraryLayout.clamped(PanelSize(width: w, height: h))
        let frame = LibraryLayout.frame(in: CGRect(x: 0, y: 0, width: 1920, height: 1080), size: PanelSize(width: w, height: h))
        // then: never below 560 x 360, each axis independently, and the placed frame agrees
        #expect(clamped.width == expectedW)
        #expect(clamped.height == expectedH)
        #expect(Double(frame.width) == expectedW)
        #expect(Double(frame.height) == expectedH)
    }

    // OC-3011. Mutation: keep the size in memory only (never write the setting).
    @Test("OC-3011 a resized panel size survives a relaunch")
    func oc3011_sizePersists() {
        // given: the Library resized to 900 x 600
        let store = ContractMemoryKV()
        SettingsLibraryPreferences(settings: SettingsStore(store: store)).panelSize = PanelSize(width: 900, height: 600)
        // when: Flotsam is relaunched (a fresh SettingsStore and preferences over the same persisted values)
        let relaunched = SettingsLibraryPreferences(settings: SettingsStore(store: store))
        // then: 900 x 600
        #expect(relaunched.panelSize.width == 900)
        #expect(relaunched.panelSize.height == 600)
    }

    // MARK: Open state (FR-003-04)

    // OC-3012. Mutation: skip any one of the resets in open(target:).
    @Test("OC-3012 reopening resets query, filter, selection, scroll and preview")
    func oc3012_openResets() async {
        // given: a session that left query 'item', the Links filter, the 5th row selected, scrolled, preview open
        let rows = Harness.rows(120)
        let h = await opened(rows, counts: SidebarCounts(all: 120, pinned: 0, kinds: [.text: 100, .link: 20], tags: [], apps: []))
        h.model.handle(key(.space))
        h.model.setSearchText("item")
        await h.model.settled()
        h.model.select(filter: .kind(.link))
        await h.model.settled()
        h.model.select(id: rows[4].id)
        h.model.loadMore()
        #expect(h.model.isPreviewOpen)
        #expect(h.model.visibleLimit == 100)
        let tokenBefore = h.model.scrollResetToken
        // when: the panel is closed and reopened
        h.model.panelDidHide()
        await h.model.open(target: target)
        // then: empty search, All, newest selected, scroll reset signalled, 50 rows visible, preview closed
        #expect(h.model.searchText == "")
        #expect(h.model.filter == .all)
        #expect(h.model.selection == [rows[0].id])
        #expect(h.model.scrollResetToken == tokenBefore + 1)
        #expect(h.model.visibleLimit == 50)
        #expect(h.model.isPreviewOpen == false)
        #expect(h.model.preview == nil)
        // and: typing 'z' is not a Library key, so it reaches the search field
        #expect(h.model.handle(key(.character("z"))) == false)
    }

    // OC-3013. Mutation: reopen keeps the previous selection.
    @Test("OC-3013 reopening selects the newest item again")
    func oc3013_newestSelected() async {
        // given: the Library open on the 4th item
        let rows = Harness.rows(8)
        let h = await opened(rows)
        h.model.select(id: rows[3].id)
        #expect(h.model.selection == [rows[3].id])
        // when: closed and reopened
        h.model.panelDidHide()
        await h.model.open(target: target)
        // then: exactly the first (newest) row is selected
        #expect(h.model.selection == [rows[0].id])
        #expect(h.model.selection.count == 1)
    }

    // OC-3015. Defect D3 (see report): jumpToLast stops at the loaded page. Mutation proof: this fails today.
    @Test("OC-3015 with 10,000 items, Command-Down reaches the oldest and the footer reads 10000 items")
    func oc3015_jumpToLastPagesIn() async {
        // given: 10,000 items, the oldest being row 9999
        let rows = Harness.rows(10_000)
        let h = await opened(rows)
        // when: Command-Down
        h.model.handle(key(.down, .command))
        await h.model.settled()
        // then: the selection is the oldest item and the count is the full 10,000
        #expect(selectedIndex(h, in: rows) == 9_999, "selected index \(selectedIndex(h, in: rows).map(String.init) ?? "nil"), loaded rows \(h.model.rowPresentations().count)")
        #expect(h.model.footer().countText == "10000 items")
    }

    // MARK: Row presentation (FR-003-06, FR-003-07)

    // OC-3018. Mutation: badge every row, or start the numbering at 0.
    @Test("OC-3018 only the first nine rows carry the Command-1 to Command-9 badge")
    func oc3018_indexBadges() async {
        // given: 12 items, opened
        let h = await opened(Harness.rows(12))
        // when: the row presentations are built
        let badges = h.model.rowPresentations().map(\.shortcutBadge)
        // then: nine badges in order, then none
        #expect(badges == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8", "⌘9", nil, nil, nil])
    }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    // OC-3019. Mutation: drop the source name from the secondary line.
    @Test("OC-3019 secondary line starts with the source app and a relative time for 2 hours ago")
    func oc3019_relativeTwoHours() {
        // given: copied 2 hours ago from Safari
        let row = fullRow(1, source: "Safari", copiedAt: Self.now.addingTimeInterval(-2 * 3600))
        // when
        let line = LibraryRowPresentation(row: row, position: 0, now: Self.now).secondaryText
        // then: 'Safari' first, then a relative phrase ending in 'ago'
        #expect(line.hasPrefix("Safari · "))
        #expect(line.hasSuffix("ago"))
        #expect(line.contains("2"))
    }

    // OC-3019. Expected to expose defect D4: the contract says 'Yesterday' (capitalised).
    @Test("OC-3019 an item from yesterday reads 'Yesterday'")
    func oc3019_yesterday() {
        // given: copied 26 hours ago (calendar yesterday) from Safari
        let row = fullRow(1, source: "Safari", copiedAt: Self.now.addingTimeInterval(-26 * 3600))
        // when
        let line = LibraryRowPresentation(row: row, position: 0, now: Self.now).secondaryText
        // then
        #expect(line == "Safari · Yesterday", "got '\(line)'")
    }

    // OC-3019. Expected to expose defect D4: after 7 days the contract wants a date, not a relative phrase.
    @Test("OC-3019 an item 10 days old shows a date, not a relative time")
    func oc3019_absoluteDate() {
        // given: copied 10 days ago from Safari
        let row = fullRow(1, source: "Safari", copiedAt: Self.now.addingTimeInterval(-10 * 86_400))
        // when
        let line = LibraryRowPresentation(row: row, position: 0, now: Self.now).secondaryText
        // then: starts with the source; what follows is a calendar date (it has digits), not a relative phrase
        #expect(line.hasPrefix("Safari · "))
        let tail = String(line.dropFirst("Safari · ".count))
        #expect(!tail.contains("ago"))
        #expect(!tail.contains("wk"))
        #expect(!tail.lowercased().contains("last"))
        #expect(tail.contains { $0.isNumber }, "a date after 7 days, got '\(tail)'")
    }

    // OC-3019. Boundary: 6 days old is still inside the relative window.
    @Test("OC-3019 an item 6 days old still reads as a relative time")
    func oc3019_sixDays() {
        // given: copied 6 days ago from Safari
        let row = fullRow(1, source: "Safari", copiedAt: Self.now.addingTimeInterval(-6 * 86_400))
        // when
        let line = LibraryRowPresentation(row: row, position: 0, now: Self.now).secondaryText
        // then: 'Safari · 6d ago'
        #expect(line.hasPrefix("Safari · "))
        #expect(line.hasSuffix("ago"))
    }

    // OC-3019. Mutation: show all tags, or cap at 2.
    @Test("OC-3019 five tags show three chips and +2")
    func oc3019_tagChips() {
        // given: an item with 5 tags
        let row = fullRow(1, tags: ["a", "b", "c", "d", "e"])
        // when
        let presentation = LibraryRowPresentation(row: row, position: 0, now: Self.now)
        // then: first three alphabetical, overflow '+2'
        #expect(presentation.tagChips == ["a", "b", "c"])
        #expect(presentation.tagOverflow == "+2")
        // and boundary: exactly 3 tags have no overflow marker
        #expect(LibraryRowPresentation(row: fullRow(2, tags: ["a", "b", "c"]), position: 0, now: Self.now).tagOverflow == nil)
    }

    // OC-3020. Mutation: swap the pinned and trigger flags, or drop the VoiceOver 'pinned'.
    @Test("OC-3020 pinned and trigger rows carry their badges; the others carry neither")
    func oc3020_badges() {
        // given: a pinned item, an item with a trigger, a plain item
        let pinned = LibraryRowPresentation(row: fullRow(1, pinned: true), position: 0, now: Self.now)
        let triggered = LibraryRowPresentation(row: fullRow(2, trigger: true), position: 1, now: Self.now)
        let plain = LibraryRowPresentation(row: fullRow(3), position: 2, now: Self.now)
        // then
        #expect(pinned.isPinned && !pinned.hasTrigger)
        #expect(pinned.accessibilityLabel.contains("pinned"))
        #expect(triggered.hasTrigger && !triggered.isPinned)
        #expect(!plain.isPinned && !plain.hasTrigger)
        #expect(!plain.accessibilityLabel.contains("pinned"))
    }

    // OC-3020 (third row). Goes through the shipping query layer: whether a file is missing is read from the disk
    // when a page is read (FR-003-07). Mutation: never set the flag, set it on every file row, or stop reading the disk
    // on the next read (restore must clear it).
    @Test("OC-3020 a file row whose file was deleted shows the Missing badge; an existing one, and a restored one, do not")
    func oc3020_missingBadge() async throws {
        // given: two file items backed by real files; one of them is then deleted
        let lib = try await RealLibrary.make()
        defer { lib.cleanUp() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oc3020-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let goneURL = dir.appendingPathComponent("gone.txt")
        let keptURL = dir.appendingPathComponent("kept.txt")
        try Data("g".utf8).write(to: goneURL)
        try Data("k".utf8).write(to: keptURL)
        let goneID = try await lib.add(.file, key: "oc3020-gone", text: "gone.txt", secondsAgo: 20,
            members: [IngestMember(path: goneURL.path, bookmark: nil, isDirectory: false)]).itemId
        let keptID = try await lib.add(.file, key: "oc3020-kept", text: "kept.txt", secondsAgo: 10,
            members: [IngestMember(path: keptURL.path, bookmark: nil, isDirectory: false)]).itemId
        let textID = try await lib.add(.text, key: "oc3020-text", text: "plain words", secondsAgo: 5).itemId
        let backup = dir.appendingPathComponent("backup.txt")
        try FileManager.default.moveItem(at: goneURL, to: backup)
        // when: the Library opens
        await lib.model.open(target: target)
        var byID = Dictionary(uniqueKeysWithValues: lib.model.rowPresentations().map { ($0.id, $0) })
        // then: the deleted-file row has the badge "Missing" and VoiceOver says so; the other two have neither
        #expect(byID.count == 3)
        #expect(byID[goneID]?.isMissing == true)
        #expect(byID[goneID]?.missingBadge == "Missing")
        #expect(byID[goneID]?.accessibilityLabel.lowercased().contains("missing") == true, "got '\(byID[goneID]?.accessibilityLabel ?? "nil")'")
        #expect(byID[keptID]?.isMissing == false)
        #expect(byID[keptID]?.missingBadge == nil)
        #expect(byID[textID]?.isMissing == false)
        #expect(byID[keptID]?.accessibilityLabel.lowercased().contains("missing") == false)
        // and when the file is restored and the rows are read again, the mark clears
        try FileManager.default.moveItem(at: backup, to: goneURL)
        await lib.model.refresh()
        byID = Dictionary(uniqueKeysWithValues: lib.model.rowPresentations().map { ($0.id, $0) })
        #expect(byID[goneID]?.isMissing == false)
    }

    // MARK: Preview member limit (FR-003-14)

    // OC-3017-adjacent, FR-003-14: up to 20 members shown, then "and {n} more". Defect D6: the product caps at 10.
    // Mutation: any other limit than 20 turns the 20/21/25 cases red.
    @Test("FR-003-14 a preview lists up to 20 members then counts the rest", arguments: [
        (0, 0, 0), (1, 1, 0), (20, 20, 0), (21, 20, 1), (25, 20, 5),
    ])
    func fr00314_memberLimit(total: Int, shown: Int, hidden: Int) {
        // given: a bundle of `total` members
        let members = (0..<total).map { ItemMember(path: "/tmp/oc/m\($0).txt", bookmark: nil, isDirectory: false) }
        let content = ItemContent(kind: .bundle, plainText: nil, representations: [], members: members)
        // when
        let preview = LibraryPreview(row: fullRow(1, kind: .bundle), content: content, imageData: nil)
        // then: the first `shown` members in order, and the remainder counted
        #expect(preview.memberPaths.count == shown)
        #expect(preview.hiddenMemberCount == hidden)
        #expect(preview.memberPaths == (0..<shown).map { "/tmp/oc/m\($0).txt" })
    }

    // FR-003-14: text up to 20,000 characters, then Show more.
    @Test("FR-003-14 text is cut at 20,000 characters and Show more reveals it all", arguments: [
        (19_999, false), (20_000, false), (20_001, true),
    ])
    func fr00314_textLimit(length: Int, truncated: Bool) {
        // given: a text item of `length` characters
        let text = String(repeating: "a", count: length)
        let preview = LibraryPreview(
            row: fullRow(1), content: ItemContent(kind: .text, plainText: text, representations: [], members: []), imageData: nil)
        // then
        #expect(preview.isTruncated == truncated)
        #expect(preview.text(showingAll: false)?.count == min(length, 20_000))
        #expect(preview.text(showingAll: true)?.count == length)
    }

    // MARK: View mode (FR-003-07)

    // OC-3022. Mutation: do not persist the toggle.
    @Test("OC-3022 Command-G switches to grid and the grid survives a relaunch")
    func oc3022_gridPersists() async {
        // given: list view, preferences backed by a persisted store
        let kv = ContractMemoryKV()
        let source = FakeSource(rows: Harness.rows(5))
        func model(_ prefs: SettingsLibraryPreferences) -> LibraryViewModel {
            LibraryViewModel(
                source: source, paster: FakePaster(), host: FakeHost(), preferences: prefs,
                effects: LibraryEffects(
                    report: { _ in }, reveal: { _ in }, openSettings: {}, external: { _, _ in }, isAccessibilityTrusted: { true }))
        }
        let first = model(SettingsLibraryPreferences(settings: SettingsStore(store: kv)))
        await first.open(target: target)
        #expect(first.viewMode == .list)
        // when: Command-G, then a relaunch (fresh preferences and model over the same store) and open
        #expect(first.handle(key(.character("g"), .command)))
        let relaunched = model(SettingsLibraryPreferences(settings: SettingsStore(store: kv)))
        await relaunched.open(target: target)
        // then: grid before and after; Command-G again returns to list
        #expect(first.viewMode == .grid)
        #expect(relaunched.viewMode == .grid)
        relaunched.handle(key(.character("g"), .command))
        #expect(relaunched.viewMode == .list)
    }

    // MARK: Keyboard navigation (FR-003-08)

    // OC-3023. Mutation: wrap at the ends, or make Command-Up/Down move by one.
    @Test("OC-3023 arrows and Command-arrows move the selection as listed")
    func oc3023_moves() async {
        // given: 5 items, list view, empty query, row 1 selected
        let rows = Harness.rows(5)
        let h = await opened(rows)
        // when/then: down, down, up, Cmd-down, Cmd-up give rows 2, 3, 2, last, first (zero-based 1, 2, 1, 4, 0)
        h.model.handle(key(.down)); #expect(selectedIndex(h, in: rows) == 1)
        h.model.handle(key(.down)); #expect(selectedIndex(h, in: rows) == 2)
        h.model.handle(key(.up)); #expect(selectedIndex(h, in: rows) == 1)
        h.model.handle(key(.down, .command)); #expect(selectedIndex(h, in: rows) == 4)
        h.model.handle(key(.up, .command)); #expect(selectedIndex(h, in: rows) == 0)
        // and boundaries: up at the top and down at the bottom stay put (no wrap)
        h.model.handle(key(.up)); #expect(selectedIndex(h, in: rows) == 0)
        h.model.handle(key(.down, .command)); h.model.handle(key(.down)); #expect(selectedIndex(h, in: rows) == 4)
    }

    // OC-3024. Mutation: right moves by a row, or down by one cell, in grid mode.
    @Test("OC-3024 in grid view right moves one cell and down moves one row")
    func oc3024_grid() async {
        // given: grid view, 10 items, 4 columns laid out by the view
        let rows = Harness.rows(10)
        let h = await opened(rows, mode: .grid)
        h.model.gridColumns = 4
        // when/then: right then down
        #expect(h.model.handle(key(.right)))
        #expect(selectedIndex(h, in: rows) == 1)
        #expect(h.model.handle(key(.down)))
        #expect(selectedIndex(h, in: rows) == 5)
        // and: in list view, right is not the Library's key (it moves the search caret)
        let list = await opened(rows)
        #expect(list.model.handle(key(.right)) == false)
        #expect(selectedIndex(list, in: rows) == 0)
    }

    // OC-3025. Mutation: Space types into the field when empty, or preview does not close.
    @Test("OC-3025 Space toggles preview with an empty query and leaves the query empty")
    func oc3025_spaceToggles() async {
        // given: empty query
        let h = await opened(Harness.rows(3))
        #expect(h.model.isPreviewOpen == false)
        // when/then: Space opens, Space closes
        #expect(h.model.handle(key(.space)))
        #expect(h.model.isPreviewOpen)
        #expect(h.model.handle(key(.space)))
        #expect(h.model.isPreviewOpen == false)
        #expect(h.model.searchText == "")
    }

    // OC-3026. Mutation: Space toggles preview even with text, or Command-Y ignored.
    @Test("OC-3026 with a query, Space types a space and Command-Y toggles preview")
    func oc3026_spaceTypesCommandY() async {
        // given: query 'a'
        let rows = (0..<3).map { makeRow($0, primary: "alpha \($0)") }
        let h = await opened(rows)
        h.model.setSearchText("a")
        await h.model.settled()
        // when: Space
        let handled = h.model.handle(key(.space))
        // then: not the Library's key (the field types the space) and preview did not toggle
        #expect(handled == false)
        #expect(h.model.isPreviewOpen == false)
        // when/then: Command-Y opens, Command-Y closes
        #expect(h.model.handle(key(.character("y"), .command)))
        #expect(h.model.isPreviewOpen)
        #expect(h.model.handle(key(.character("y"), .command)))
        #expect(h.model.isPreviewOpen == false)
        #expect(h.model.searchText == "a")
    }

    // OC-3027. Mutation: reorder the ladder, or close the panel on the first Esc.
    @Test("OC-3027 Esc clears the query, then closes preview, then closes the panel")
    func oc3027_escLadder() async {
        // given: query 'x' with preview open
        let rows = (0..<3).map { makeRow($0, primary: "x item \($0)") }
        let h = await opened(rows)
        h.model.handle(key(.space))
        h.model.setSearchText("x")
        await h.model.settled()
        #expect(h.model.isPreviewOpen)
        // when/then: first Esc clears the query only
        h.model.handle(key(.escape))
        await h.model.settled()
        #expect(h.model.searchText == "")
        #expect(h.model.isPreviewOpen)
        #expect(h.host.hideCount == 0)
        // second Esc closes preview only
        h.model.handle(key(.escape))
        #expect(h.model.isPreviewOpen == false)
        #expect(h.host.hideCount == 0)
        // third Esc closes the panel
        h.model.handle(key(.escape))
        #expect(h.host.hideCount == 1)
    }

    // OC-3028. Mutation: skip Pinned, wrap at the ends, or reverse the direction.
    @Test("OC-3028 Option-Down and Option-Up walk the sidebar: All, Pinned, first type, Pinned")
    func oc3028_sidebarStep() async {
        // given: sidebar on All, with Text and Links types present
        let counts = SidebarCounts(all: 5, pinned: 1, kinds: [.text: 3, .link: 2], tags: [], apps: [])
        let h = await opened(Harness.rows(5), counts: counts)
        #expect(h.model.filter == .all)
        // when/then
        h.model.handle(key(.down, .option)); #expect(h.model.filter == .pinned)
        h.model.handle(key(.down, .option)); #expect(h.model.filter == .kind(.text))
        h.model.handle(key(.up, .option)); #expect(h.model.filter == .pinned)
        // and boundary: Option-Up twice from Pinned stops at All
        h.model.handle(key(.up, .option)); h.model.handle(key(.up, .option))
        #expect(h.model.filter == .all)
    }
}
