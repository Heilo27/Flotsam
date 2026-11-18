import Foundation
import Testing
@testable import FlotsamBase

/// A clock whose `sleep` parks until the test releases it, so the refresh loop advances only when told to.
@MainActor
private final class ParkedClock: WallClock {
    nonisolated func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private(set) var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func sleep(for duration: Duration) async {
        await park(duration)
    }

    private func park(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { waiters.append($0) }
    }

    var parked: Int { waiters.count }

    func releaseAll() {
        let all = waiters
        waiters = []
        for waiter in all { waiter.resume() }
    }
}

/// Yields until `condition` holds (bounded), so a test waits on state rather than on time.
@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<2_000 where !condition() { await Task.yield() }
}

/// What the status read stands for: a permission the test flips, and a count of how often it was read.
@MainActor
private final class StatusProbe {
    var granted = false
    private(set) var reads = 0
    private(set) var shown = false
    func refresh() { reads += 1; shown = granted }
}

@MainActor
@Suite struct Task450VisibleRefreshTests {
    @Test func intervalIsTwoSeconds() {
        #expect(VisibleRefresh.interval == .seconds(2))
    }

    // AC 1: a grant made while the pane stays visible shows on the next 2 s read.
    @Test func aChangeWhileVisibleShowsOnTheNextRead() async {
        let clock = ParkedClock()
        let probe = StatusProbe()
        let refresher = VisibleRefresh(clock: clock) { probe.refresh() }

        refresher.setVisible(true)
        await settle { clock.parked == 1 }
        #expect(probe.reads == 1, "reads at once on becoming visible")
        #expect(!probe.shown)
        #expect(clock.requested == [.seconds(2)])

        probe.granted = true
        clock.releaseAll()  // the 2 s elapse
        await settle { probe.reads == 2 }
        #expect(probe.shown, "the status follows the change within one interval")
        refresher.setVisible(false)
    }

    // AC 2: hidden means nothing is read, however long the clock runs.
    @Test func hiddenStopsTheReads() async {
        let clock = ParkedClock()
        let probe = StatusProbe()
        let refresher = VisibleRefresh(clock: clock) { probe.refresh() }

        refresher.setVisible(true)
        await settle { clock.parked == 1 }
        refresher.setVisible(false)
        #expect(!refresher.isRefreshing)

        clock.releaseAll()  // the sleep that was already running ends
        for _ in 0..<200 { await Task.yield() }
        #expect(probe.reads == 1, "no read after hide")
        #expect(clock.parked == 0, "no new sleep is scheduled after hide")
    }

    @Test func neverVisibleNeverReads() async {
        let probe = StatusProbe()
        let refresher = VisibleRefresh(clock: ParkedClock()) { probe.refresh() }
        refresher.setVisible(false)
        for _ in 0..<50 { await Task.yield() }
        #expect(probe.reads == 0)
        #expect(!refresher.isRefreshing)
    }

    @Test func showingTwiceDoesNotStartASecondLoop() async {
        let clock = ParkedClock()
        let probe = StatusProbe()
        let refresher = VisibleRefresh(clock: clock) { probe.refresh() }

        refresher.setVisible(true)
        refresher.setVisible(true)
        await settle { clock.parked >= 1 }
        for _ in 0..<50 { await Task.yield() }
        #expect(clock.parked == 1)
        #expect(probe.reads == 1)
        refresher.setVisible(false)
    }

    @Test func visibleAgainReadsAtOnceAndResumes() async {
        let clock = ParkedClock()
        let probe = StatusProbe()
        let refresher = VisibleRefresh(clock: clock) { probe.refresh() }

        refresher.setVisible(true)
        await settle { clock.parked == 1 }
        refresher.setVisible(false)
        clock.releaseAll()
        for _ in 0..<50 { await Task.yield() }
        #expect(probe.reads == 1)

        probe.granted = true
        refresher.setVisible(true)
        await settle { clock.parked == 1 }
        #expect(probe.reads == 2 && probe.shown, "a pane shown again is current before the first interval")
        refresher.setVisible(false)
    }
}

// TASK-450 re-work: the window-event -> visible rule, as a pure function (the App modifier only feeds it).
@Suite struct Task450VisibilityRuleTests {
    @Test func appearedInAVisibleWindowIsVisible() {
        #expect(VisibleRefresh.isVisible(onScreen: true, windowIsVisible: true))
    }

    @Test func closedMinimisedOrCoveredWindowIsNotVisible() {
        // a closed, a minimised and a fully covered window all report an occlusion state without .visible
        #expect(!VisibleRefresh.isVisible(onScreen: true, windowIsVisible: false))
    }

    @Test func noWindowIsNotVisible() {
        #expect(!VisibleRefresh.isVisible(onScreen: true, windowIsVisible: nil))
    }

    @Test func disappearedPaneIsNotVisibleEvenInAVisibleWindow() {
        #expect(!VisibleRefresh.isVisible(onScreen: false, windowIsVisible: true))
    }

    @Test func offScreenAndNoWindowIsNotVisible() {
        #expect(!VisibleRefresh.isVisible(onScreen: false, windowIsVisible: nil))
        #expect(!VisibleRefresh.isVisible(onScreen: false, windowIsVisible: false))
    }

    // appear -> close -> reopen -> pane switch away, as the sequence of (onScreen, windowIsVisible) the modifier sees
    @Test func eventSequenceFollowsTheWindow() {
        let events: [(Bool, Bool?)] = [(true, nil), (true, true), (true, false), (true, true), (false, true)]
        #expect(events.map { VisibleRefresh.isVisible(onScreen: $0.0, windowIsVisible: $0.1) } == [false, true, false, true, false])
    }
}
