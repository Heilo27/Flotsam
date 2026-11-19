import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-257 QA (Worf, blind): FR-004-13 / OC-4099 under bursts and hide/show races. Expected values are literals taken
// from the FRD (the counts and footer equal the rows in the store once changes stop), not from the model.

private final class WGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool) { isOpen = open }
    func wait() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
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

private final class WSource: LibraryDataSource, @unchecked Sendable {
    let inner: FakeSource
    private let lock = NSLock()
    private var _gate = WGate(open: true)
    private var _reads = 0
    init(rows: [ItemRow]) { inner = FakeSource(rows: rows) }
    var gate: WGate {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }
    var reads: Int { lock.withLock { _reads } }
    func setRows(_ count: Int) {
        let rows = (1...max(count, 1)).prefix(count).map { makeRow($0) }
        inner.rows = Array(rows)
        inner.counts = SidebarCounts(all: count, pinned: 0, kinds: [.text: count], tags: [], apps: [])
    }
    func items(matching query: LibraryQuery) async -> FlotsamResult<ItemPage> { await inner.items(matching: query) }
    func sidebarCounts() async -> FlotsamResult<SidebarCounts> {
        let gate = lock.withLock { () -> WGate in
            _reads += 1
            return _gate
        }
        await gate.wait()
        return await inner.sidebarCounts()
    }
    func content(of itemId: UUID) async -> FlotsamResult<ItemContent> { await inner.content(of: itemId) }
    func thumbnail(itemId: UUID, size: ThumbnailSize) async -> Data? { await inner.thumbnail(itemId: itemId, size: size) }
    func releaseMemory() async { await inner.releaseMemory() }
}

@MainActor
private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
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
private func quiesce() async {
    for round in 0..<600 { if round % 16 == 15 { await Task.detached {}.value } else { await Task.yield() } }
}

@MainActor
private struct WRig {
    let source: WSource
    let events = ItemEventBus()
    let model: LibraryViewModel
    init(count: Int) {
        source = WSource(rows: (1...count).map { makeRow($0) })
        model = LibraryViewModel(
            source: source, paster: FakePaster(), host: FakeHost(), preferences: FakePreferences(),
            effects: LibraryEffects(isAccessibilityTrusted: { true }), events: events)
    }
}

@MainActor
@Suite struct Worf257LiveCountsTests {
    @Test("OC-4099 burst: 25 captures while a reload is blocked end with counts, footer and rows all at 28 and the selection kept")
    func burstEndsConsistent() async {
        let rig = WRig(count: 3)
        await rig.model.open(target: nil)
        rig.model.select(id: makeRow(2).id)
        let before = rig.source.reads

        rig.source.gate = WGate(open: false)
        rig.source.setRows(4)
        rig.events.publish(.itemsChanged)
        #expect(await waitFor { rig.source.reads == before + 1 })
        for n in 5...28 {
            rig.source.setRows(n)
            rig.events.publish(.itemsChanged)
        }
        rig.source.gate.release()
        #expect(await waitFor { rig.model.sidebar?.all == 28 && rig.model.loadedRows.count == 28 }, "stale count after a burst")
        await quiesce()
        await rig.model.settled()
        #expect(rig.model.sidebar?.all == 28)
        #expect(rig.model.footer().countText == "28 items")
        #expect(rig.model.loadedRows.count == 28)
        #expect(rig.model.selection == [makeRow(2).id], "the burst moved the selection")
    }

    @Test("FR-003-13 three hide/show cycles leak nothing: one change then costs exactly one reload (plus none queued)")
    func hideShowLeaksNoSubscription() async {
        let rig = WRig(count: 3)
        for _ in 0..<3 {
            await rig.model.open(target: nil)
            rig.model.panelDidHide()
        }
        await rig.model.open(target: nil)
        await quiesce()
        let before = rig.source.reads

        rig.source.gate = WGate(open: false)
        rig.source.setRows(4)
        rig.events.publish(.itemsChanged)
        #expect(await waitFor { rig.source.reads == before + 1 })
        await quiesce()
        rig.source.gate.release()
        #expect(await waitFor { rig.model.sidebar?.all == 4 })
        await quiesce()
        await rig.model.settled()
        // One subscription means one handler, so exactly one reload ran. Leaked handlers queue extra reloads.
        #expect(rig.source.reads == before + 1, "a stale subscription from an earlier show reloaded again")
    }

    @Test("FR-003-13 a change published while hidden does no reads, and the next show picks it up")
    func hiddenIgnoresThenShowCatchesUp() async {
        let rig = WRig(count: 3)
        await rig.model.open(target: nil)
        rig.model.panelDidHide()
        let before = rig.source.reads
        rig.source.setRows(6)
        rig.events.publish(.itemsChanged)
        await quiesce()
        #expect(rig.source.reads == before, "a hidden panel reloaded")
        #expect(rig.model.sidebar?.all == 3)
        await rig.model.open(target: nil)
        #expect(rig.model.sidebar?.all == 6 && rig.model.footer().countText == "6 items")
    }

    @Test("FR-004-13 hide during a blocked reload then show: the old reload is dead, the new one wins, and later changes reload at once")
    func hideShowDuringReload() async {
        let rig = WRig(count: 3)
        await rig.model.open(target: nil)
        let blocked = WGate(open: false)
        rig.source.gate = blocked
        rig.source.setRows(4)
        rig.events.publish(.itemsChanged)
        let before = rig.source.reads
        #expect(await waitFor { rig.source.reads == before + 1 })

        rig.model.panelDidHide()
        rig.source.gate = WGate(open: true)
        rig.source.setRows(5)
        await rig.model.open(target: nil)
        #expect(rig.model.sidebar?.all == 5)
        blocked.release()   // the cancelled reload's read returns late with whatever it read
        await quiesce()
        #expect(rig.model.sidebar?.all == 5 && rig.model.loadedRows.count == 5, "the dead reload applied")

        let again = rig.source.reads
        rig.source.setRows(7)
        rig.events.publish(.itemsChanged)
        #expect(await waitFor { rig.model.sidebar?.all == 7 }, "the flag stayed stuck in flight: the change was queued forever")
        #expect(rig.source.reads == again + 1)
    }

    @Test("FR-004-13 an empty library: the last item deleted leaves 0 counts and an empty footer state, not the old 1")
    func lastItemDeleted() async {
        let rig = WRig(count: 1)
        await rig.model.open(target: nil)
        #expect(rig.model.sidebar?.all == 1)
        rig.source.inner.rows = []
        rig.source.inner.counts = SidebarCounts(all: 0, pinned: 0, kinds: [:], tags: [], apps: [])
        rig.events.publish(.itemsDeleted([makeRow(1).id]))
        #expect(await waitFor { rig.model.sidebar?.all == 0 })
        #expect(rig.model.loadedRows.isEmpty && rig.model.selection.isEmpty)
    }

    @Test("FR-004-13 a second open without a hide in between does not stack subscriptions: after hide and show one change is one reload")
    func doubleOpenStacksNothing() async {
        let rig = WRig(count: 3)
        await rig.model.open(target: nil)
        await rig.model.open(target: nil)
        rig.model.panelDidHide()
        await rig.model.open(target: nil)
        await quiesce()
        let before = rig.source.reads
        rig.source.gate = WGate(open: false)
        rig.source.setRows(4)
        rig.events.publish(.itemsChanged)
        #expect(await waitFor { rig.source.reads == before + 1 })
        await quiesce()
        rig.source.gate.release()
        #expect(await waitFor { rig.model.sidebar?.all == 4 })
        await quiesce()
        #expect(rig.source.reads == before + 1, "a leaked handler from the double open reloaded again")
    }

    @Test("FR-004-13 a change queued behind a reload is dropped when a newer reload (a sort change) starts after it: 2 reloads, not 3")
    func newerReloadSupersedesQueued() async {
        let rig = WRig(count: 3)
        await rig.model.open(target: nil)
        let before = rig.source.reads
        rig.source.gate = WGate(open: false)
        rig.source.setRows(4)
        rig.events.publish(.itemsChanged)
        #expect(await waitFor { rig.source.reads == before + 1 })
        rig.source.setRows(5)
        rig.events.publish(.itemsChanged)
        await quiesce()
        rig.model.cycleSort()
        #expect(await waitFor { rig.source.reads == before + 2 })
        rig.source.gate.release()
        #expect(await waitFor { rig.model.sidebar?.all == 5 })
        await quiesce()
        #expect(rig.source.reads == before + 2, "a stale queued flag ran a redundant third reload")
    }
}
