import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-257 / FR-004-13 / OC-4099 (the 200 ms clause and the capture-arrival wiring): the sidebar counts and the footer
// update when storage publishes a change (a capture, or any commit) while the panel is shown, with no refresh call.
//
// How the 200 ms bound is asserted without a wall clock: the subscription is the only path from a commit to a reload.
// The model puts no timer, debounce or poll on that path, so the latency from commit to counts is the latency of one
// reload (a count query and a page query, measured against 10,000 items by OC-4230). The tests below pin the two
// halves the package can pin: (1) the event starts the reload at once, with the data source still blocked, so nothing
// waits on a timer; (2) the counts and footer are applied by that reload with no further call. A debounce added to the
// path would hold the fetch back and turn (1) red.

private let fileClassifiers = ItemClassifiers(
    editedText: { ItemClassification(kind: .text, contentKey: "edit:" + $0) },
    fileMember: { path, isDirectory in ItemClassification(kind: isDirectory ? .folder : .file, contentKey: "file:" + path) })

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool) { isOpen = open }
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
}

/// `FakeSource` with the sidebar-counts read held behind a gate, so a test sees what the model does while a reload is
/// in flight.
private final class GatedSource: LibraryDataSource, @unchecked Sendable {
    let inner: FakeSource
    private let lock = NSLock()
    private var _gate = Gate(open: true)
    private var _countsReads = 0
    init(rows: [ItemRow]) { inner = FakeSource(rows: rows) }
    var gate: Gate {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }
    var countsReads: Int { lock.withLock { _countsReads } }
    /// Adds a row the way a capture would: the next page and the next counts both include it.
    func addRow(_ row: ItemRow) {
        inner.rows.insert(row, at: 0)
        inner.counts = SidebarCounts(all: inner.rows.count, pinned: 0, kinds: [.text: inner.rows.count], tags: [], apps: [])
    }
    func items(matching query: LibraryQuery) async -> FlotsamResult<ItemPage> { await inner.items(matching: query) }
    func sidebarCounts() async -> FlotsamResult<SidebarCounts> {
        let gate = lock.withLock { () -> Gate in
            _countsReads += 1
            return _gate
        }
        await gate.wait()
        return await inner.sidebarCounts()
    }
    func content(of itemId: UUID) async -> FlotsamResult<ItemContent> { await inner.content(of: itemId) }
    func thumbnail(itemId: UUID, size: ThumbnailSize) async -> Data? { await inner.thumbnail(itemId: itemId, size: size) }
    func releaseMemory() async { await inner.releaseMemory() }
}

/// Lets other tasks run until `condition` holds. The reload's reads run off the main actor, so a loaded machine can
/// delay them for a while; the failure cap is therefore a generous wall-clock limit (30 s, reached only on failure and
/// turned into the caller's `#expect` failure), not a yield count. A passing run returns the moment the condition holds.
@MainActor
private func pump(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    var round = 0
    while ContinuousClock.now < deadline {
        if condition() { return true }
        round += 1
        if round % 16 == 0 { await Task.detached {}.value } else { await Task.yield() }
    }
    return condition()
}

@MainActor
private struct LiveRig {
    let source: GatedSource
    let events = ItemEventBus()
    let model: LibraryViewModel

    init(rows: [ItemRow]) {
        source = GatedSource(rows: rows)
        model = LibraryViewModel(
            source: source, paster: FakePaster(), host: FakeHost(), preferences: FakePreferences(),
            effects: LibraryEffects(isAccessibilityTrusted: { true }), events: events)
    }
}

@MainActor
@Suite struct Task257LiveCountsTests {
    private let threeRows = [makeRow(1), makeRow(2), makeRow(3)]

    @Test("OC-4099 a capture published while the panel is shown starts a reload at once, with no timer on the path, and the counts and footer follow with no refresh call")
    func captureReloadsAtOnce() async {
        let rig = LiveRig(rows: threeRows)
        await rig.model.open(target: nil)
        #expect(rig.model.sidebar?.all == 3 && rig.model.footer().countText == "3 items")
        let readsBefore = rig.source.countsReads

        rig.source.gate = Gate(open: false)
        rig.source.addRow(makeRow(4))
        rig.events.publish(.itemsChanged)

        // The reload is under way (its counts read is waiting at the gate) with nothing else done: no clock was advanced
        // and nothing was called. The counts shown are still the old ones until the read returns.
        #expect(await pump { rig.source.countsReads == readsBefore + 1 }, "the change did not start a reload")
        #expect(rig.model.sidebar?.all == 3)

        rig.source.gate.release()
        await rig.model.settled()
        #expect(rig.model.sidebar?.all == 4 && rig.model.sidebar?.kinds == [.text: 4])
        #expect(rig.model.footer().countText == "4 items" && rig.model.loadedRows.count == 4)
    }

    @Test("OC-4099 an item deleted elsewhere (a deletion event) drops the counts and the footer the same way")
    func deletionReloads() async {
        let rig = LiveRig(rows: threeRows)
        await rig.model.open(target: nil)
        let readsBefore = rig.source.countsReads
        rig.source.inner.rows.removeLast()
        rig.source.inner.counts = SidebarCounts(all: 2, pinned: 0, kinds: [.text: 2], tags: [], apps: [])
        rig.events.publish(.itemsDeleted([makeRow(3).id]))
        #expect(await pump { rig.source.countsReads == readsBefore + 1 })
        await rig.model.settled()
        #expect(rig.model.sidebar?.all == 2 && rig.model.footer().countText == "2 items")
    }

    @Test("FR-003-13 a hidden panel does no work: no reload for a change before the first open or after a hide")
    func hiddenPanelIgnoresChanges() async {
        let rig = LiveRig(rows: threeRows)
        rig.events.publish(.itemsChanged)
        for _ in 0..<2_000 { await Task.yield() }
        #expect(rig.source.inner.queries.isEmpty, "a never-opened model must not load on a change")

        await rig.model.open(target: nil)
        rig.model.panelDidHide()
        let queriesAfterHide = rig.source.inner.queries.count
        let readsAfterHide = rig.source.countsReads
        rig.source.addRow(makeRow(4))
        rig.events.publish(.itemsChanged)
        for _ in 0..<2_000 { await Task.yield() }
        #expect(rig.source.inner.queries.count == queriesAfterHide && rig.source.countsReads == readsAfterHide)

        // opening again subscribes again
        await rig.model.open(target: nil)
        #expect(rig.model.sidebar?.all == 4)
        let readsAfterOpen = rig.source.countsReads
        rig.source.addRow(makeRow(5))
        rig.events.publish(.itemsChanged)
        #expect(await pump { rig.source.countsReads == readsAfterOpen + 1 })
        await rig.model.settled()
        #expect(rig.model.sidebar?.all == 5)
    }

    @Test("FR-004-13 a change that lands while a reload is running is not lost: the running reload finishes, then one more runs and shows the newer counts")
    func changeDuringReloadIsQueued() async {
        let rig = LiveRig(rows: threeRows)
        await rig.model.open(target: nil)
        let readsBefore = rig.source.countsReads

        rig.source.gate = Gate(open: false)
        rig.source.addRow(makeRow(4))
        rig.events.publish(.itemsChanged)
        #expect(await pump { rig.source.countsReads == readsBefore + 1 })

        // a second capture arrives while the first reload is blocked
        rig.source.addRow(makeRow(5))
        rig.events.publish(.itemsChanged)
        rig.source.gate.release()
        #expect(await pump { rig.source.countsReads == readsBefore + 2 }, "the second change started no follow-up reload")
        await rig.model.settled()
        #expect(rig.model.sidebar?.all == 5 && rig.model.footer().countText == "5 items")
    }

    @Test("FR-003-13 a change published while shown, whose handler runs after the panel hid, does no work")
    func changeLandingAfterHideIsIgnored() async {
        let rig = LiveRig(rows: threeRows)
        await rig.model.open(target: nil)
        let readsBefore = rig.source.countsReads
        let queriesBefore = rig.source.inner.queries.count

        // The bus hands the event to the main actor; the panel hides before that hop runs (no suspension in between).
        rig.events.publish(.itemsChanged)
        rig.model.panelDidHide()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(rig.source.countsReads == readsBefore && rig.source.inner.queries.count == queriesBefore,
                "a hidden panel reloaded for a change that landed after it hid")
    }

    @Test("FR-004-13 a change that lands during a command's own refresh does not cancel it: the command's selection wins")
    func changeDuringCommandRefreshDoesNotCancelIt() async {
        let rig = LiveRig(rows: threeRows)
        await rig.model.open(target: nil)
        let readsBefore = rig.source.countsReads
        let wanted = makeRow(3).id

        rig.source.gate = Gate(open: false)
        let refresh = Task { @MainActor in await rig.model.refresh(selecting: [wanted]) }
        #expect(await pump { rig.source.countsReads == readsBefore + 1 })

        // storage echoes the command's own commit while its refresh is still reading
        rig.events.publish(.itemsChanged)
        for _ in 0..<2_000 { await Task.yield() }
        #expect(rig.source.countsReads == readsBefore + 1, "the change started a second reload on top of the running one")

        rig.source.gate.release()
        await refresh.value
        #expect(await pump { rig.source.countsReads == readsBefore + 2 }, "the queued change never reloaded")
        await rig.model.settled()
        #expect(rig.model.selection == [wanted], "the echoed change replaced the command's selection")
    }

    @Test("FR-004-13 a change reload keeps the selection and the scroll depth: the selected row stays selected when a capture arrives")
    func changeReloadKeepsSelection() async {
        let rig = LiveRig(rows: threeRows)
        await rig.model.open(target: nil)
        rig.model.select(id: makeRow(2).id)
        let token = rig.model.scrollResetToken
        let readsBefore = rig.source.countsReads
        rig.source.addRow(makeRow(4))
        rig.events.publish(.itemsChanged)
        #expect(await pump { rig.source.countsReads == readsBefore + 1 })
        await rig.model.settled()
        #expect(rig.model.sidebar?.all == 4)
        #expect(rig.model.selection == [makeRow(2).id], "a capture must not move the person's selection")
        #expect(rig.model.scrollResetToken == token, "a capture must not scroll the list back to the top")
    }
}

// MARK: Real storage: the event comes from the ingest path itself

@MainActor
@Suite struct Task257LiveCountsStorageTests {
    @MainActor private struct Rig {
        let root: URL
        let database: FlotsamDatabase
        let ingest: IngestActor
        let organizer: LibraryOrganizer
        let model: LibraryViewModel

        static func make() async throws -> Rig {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-task257-\(UUID().uuidString)")
            let database = try await FlotsamDatabase.open(folder: root).get()
            let ingest = IngestActor(database: database, settings: SettingsStore(store: ContractMemoryKV()))
            let organizer = LibraryOrganizer(store: database, classifiers: fileClassifiers, report: { _ in })
            let model = LibraryViewModel(
                source: database, paster: FakePaster(), host: FakeHost(), preferences: FakePreferences(),
                effects: LibraryEffects(isAccessibilityTrusted: { true }), organizer: organizer, events: database.events)
            return Rig(root: root, database: database, ingest: ingest, organizer: organizer, model: model)
        }

        @discardableResult
        func add(_ kind: ItemKind, key: String, text: String? = nil, members: [IngestMember] = []) async throws -> UUID {
            let candidate = IngestCandidate(
                kind: kind, contentKey: key, plainText: text, representations: [], members: members,
                source: SourceApp(bundleId: "com.example.notes", name: "Notes"), origin: .pasteboard,
                occurredAt: Date(), originalPath: nil)
            return try await ingest.ingest(candidate).get().itemId
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("OC-4099 over real storage: a capture ingested while the Library is open reaches the sidebar and footer with no refresh call, and a hidden Library is left alone")
    func realCaptureArrival() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        try await rig.add(.text, key: "t1", text: "one")
        try await rig.add(.text, key: "t2", text: "two")
        await rig.model.open(target: nil)
        #expect(rig.model.sidebar?.all == 2 && rig.model.footer().countText == "2 items")

        try await rig.add(.text, key: "t3", text: "three")
        #expect(await pump { rig.model.sidebar?.all == 3 && rig.model.loadedRows.count == 3 })
        #expect(rig.model.footer().countText == "3 items")

        rig.model.panelDidHide()
        try await rig.add(.text, key: "t4", text: "four")
        for _ in 0..<2_000 { await Task.yield() }
        #expect(rig.model.sidebar?.all == 3, "a hidden Library does not reload")
    }

    @Test("FR-004-13 over real storage: with the change feed wired, a command's own refresh still wins, so the ungrouped files stay selected and the counts are the post-command ones")
    func commandRefreshSurvivesTheEchoedEvent() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let bundleMembers = (1...2).map { IngestMember(path: "/task257/b1/f\($0).txt", bookmark: nil, isDirectory: false) }
        try await rig.add(.text, key: "t1", text: "one")
        let bundle = try await rig.add(.bundle, key: "b1", members: bundleMembers)
        await rig.model.open(target: nil)
        #expect(rig.model.sidebar?.all == 2)

        rig.model.select(id: bundle)
        let files = try #require(await rig.model.ungroupSelected())
        #expect(files.count == 2)
        // Right after the command returns, before the echoed change event has been serviced.
        #expect(rig.model.selection == Set(files), "the command's own selection was overwritten by the change reload")
        #expect(rig.model.sidebar?.all == 3 && rig.model.sidebar?.kinds[.file] == 2 && rig.model.sidebar?.kinds[.bundle] == nil)

        // After the echoed event and any queued reload have run, nothing moved.
        for _ in 0..<5_000 { await Task.yield() }
        await rig.model.settled()
        #expect(rig.model.selection == Set(files))
        #expect(rig.model.sidebar?.all == 3 && rig.model.footer().countText == "2 selected" && rig.model.totalCount == 3)
    }
}
