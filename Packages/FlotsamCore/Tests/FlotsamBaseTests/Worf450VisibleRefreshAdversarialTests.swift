import Foundation
import Testing
@testable import FlotsamBase

// TASK-450 adversarial (FRD-008 FR-008-13 rule b, AC-008-08). The App-target modifier turns window events (close,
// minimise, occlude, pane switch) into `setVisible(Bool)`; these tests drive every such event sequence at the seam and
// observe the two things a user or the idle budget can feel: how often the status was read, and whether a sleep is
// still scheduled. Expected values are literals only.

/// Parks every sleep until released and, unlike a real clock, ignores cancellation, so a loop that is not cancelled
/// shows up as extra reads after release.
@MainActor
private final class HoldClock: WallClock {
    nonisolated func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private(set) var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func sleep(for duration: Duration) async { await park(duration) }

    private func park(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { waiters.append($0) }
    }

    var parked: Int { waiters.count }

    func release() {
        let all = waiters
        waiters = []
        for waiter in all { waiter.resume() }
    }
}

/// Returns at once (after one yield) and counts calls: lets a loop spin as if time passed, so "nothing while hidden"
/// is checked over many virtual intervals without waiting.
@MainActor
private final class SpinClock: WallClock {
    nonisolated func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private(set) var sleeps = 0
    private(set) var durations: Set<Duration> = []

    nonisolated func sleep(for duration: Duration) async { await tick(duration) }

    private func tick(_ duration: Duration) async {
        sleeps += 1
        durations.insert(duration)
        await Task.yield()
    }
}

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<5_000 where !condition() { await Task.yield() }
}

@MainActor
private func drain(_ turns: Int = 300) async {
    for _ in 0..<turns { await Task.yield() }
}

@MainActor
private final class Reads {
    var granted = false
    private(set) var count = 0
    private(set) var shown = false
    func read() { count += 1; shown = granted }
}

@MainActor
@Suite struct Worf450VisibleRefreshAdversarialTests {
    // OC-450-01. Given a visible pane. When the window closes (hide) and the held 2 s sleep then ends.
    // Then no further read happens and no new sleep is scheduled. Red if: setVisible(false) does not cancel the loop.
    @Test func closeStopsTheLoopEvenWhenThePendingSleepEnds() async {
        let clock = HoldClock(), reads = Reads()
        let refresher = VisibleRefresh(clock: clock) { reads.read() }
        refresher.setVisible(true)
        await settle { clock.parked == 1 }

        refresher.setVisible(false)
        clock.release()
        await drain()

        #expect(reads.count == 1)
        #expect(clock.parked == 0)
        #expect(clock.requested == [.seconds(2)])
        #expect(!refresher.isRefreshing)
    }

    // OC-450-02. Given a pane that is on screen, minimised, then restored. When it is restored.
    // Then it reads at once (current before the first interval) and resumes a 2 s cadence: 3 reads total, 1 sleep parked.
    // Red if: becoming visible does not read immediately, or a minimise does not stop the loop.
    @Test func minimiseThenRestoreReadsAtOnceAndResumes() async {
        let clock = HoldClock(), reads = Reads()
        let refresher = VisibleRefresh(clock: clock) { reads.read() }
        refresher.setVisible(true)
        await settle { clock.parked == 1 }
        refresher.setVisible(false)  // minimise
        clock.release()
        await drain()
        #expect(reads.count == 1)

        reads.granted = true  // granted while the window was away
        refresher.setVisible(true)  // restore
        await settle { clock.parked == 1 }
        #expect(reads.count == 2)
        #expect(reads.shown)

        clock.release()
        await settle { reads.count == 3 }
        #expect(reads.count == 3)
        refresher.setVisible(false)
    }

    // OC-450-03. Given a window that is occluded and un-occluded repeatedly (the window notification repeats the same
    // state). When setVisible(false) arrives twice and setVisible(true) three times in a row.
    // Then there is exactly one loop: 1 read, 1 parked sleep. Red if: a second Task starts or hide is not idempotent.
    @Test func repeatedSameStateSignalsNeitherDoubleNorCrash() async {
        let clock = HoldClock(), reads = Reads()
        let refresher = VisibleRefresh(clock: clock) { reads.read() }
        refresher.setVisible(false)
        refresher.setVisible(false)
        refresher.setVisible(true)
        refresher.setVisible(true)
        refresher.setVisible(true)
        await settle { clock.parked >= 1 }
        await drain()

        #expect(reads.count == 1)
        #expect(clock.parked == 1)
        #expect(clock.requested == [.seconds(2)])
        refresher.setVisible(false)
    }

    // OC-450-04. Given 50 rapid show/hide flips ending hidden (a pane switch storm). When the loop would run.
    // Then not one read happened and nothing is parked. Red if: a task that was cancelled before it first ran still reads.
    @Test func rapidFlipsEndingHiddenNeverRead() async {
        let clock = HoldClock(), reads = Reads()
        let refresher = VisibleRefresh(clock: clock) { reads.read() }
        for _ in 0..<50 {
            refresher.setVisible(true)
            refresher.setVisible(false)
        }
        await drain()
        clock.release()
        await drain()

        #expect(reads.count == 0)
        #expect(clock.parked == 0)
        #expect(clock.requested.isEmpty)
        #expect(!refresher.isRefreshing)
    }

    // OC-450-05. Given 50 rapid flips ending visible. When the clock is released.
    // Then exactly one loop survives: 1 read, 1 parked sleep, and after release exactly 1 more read (not 50).
    // Red if: stale tasks from earlier flips keep reading or two loops run.
    @Test func rapidFlipsEndingVisibleLeaveExactlyOneLoop() async {
        let clock = HoldClock(), reads = Reads()
        let refresher = VisibleRefresh(clock: clock) { reads.read() }
        for _ in 0..<50 {
            refresher.setVisible(true)
            refresher.setVisible(false)
        }
        refresher.setVisible(true)
        await settle { clock.parked == 1 }
        await drain()
        #expect(reads.count == 1)
        #expect(clock.parked == 1)

        clock.release()
        await settle { reads.count == 2 }
        await drain()
        #expect(reads.count == 2)
        #expect(clock.parked == 1)
        refresher.setVisible(false)
    }

    // OC-450-06. Given a hide then a show while the old 2 s sleep is still pending. When that old sleep ends.
    // Then the old loop does not read a second time alongside the new one (reads: 2 not 3).
    // Red if: hide does not cancel the old task (two loops after show).
    @Test func hideShowWhileOldSleepPendingDoesNotDoubleTheCadence() async {
        let clock = HoldClock(), reads = Reads()
        let refresher = VisibleRefresh(clock: clock) { reads.read() }
        refresher.setVisible(true)
        await settle { clock.parked == 1 }
        refresher.setVisible(false)
        refresher.setVisible(true)
        await settle { clock.parked == 2 }  // old (uncancelled by this clock) + new
        #expect(reads.count == 2)

        clock.release()
        await drain()
        // The old loop wakes cancelled and stops; the new loop reads once. Total 3 reads here (1 + 1 + 1).
        #expect(reads.count == 3)
        #expect(clock.parked == 1)
        refresher.setVisible(false)
    }

    // OC-450-07. Given a loop that has run for many virtual intervals. When hidden.
    // Then reads and sleeps freeze at the value at hide time across 500 further turns (no idle wake-ups hidden),
    // and every sleep it ever requested was exactly 2 s. Red if: hide leaves the loop running or the cadence drifts.
    @Test func hiddenMeansZeroWakeUpsOverManyVirtualIntervals() async {
        let clock = SpinClock(), reads = Reads()
        let refresher = VisibleRefresh(clock: clock) { reads.read() }
        refresher.setVisible(true)
        await settle { reads.count >= 5 }
        #expect(reads.count >= 5, "visible: the loop really runs")

        refresher.setVisible(false)
        let readsAtHide = reads.count
        let sleepsAtHide = clock.sleeps
        await drain(500)

        #expect(reads.count == readsAtHide)
        #expect(clock.sleeps == sleepsAtHide)
        #expect(clock.durations == [.seconds(2)])
    }

    // OC-450-08. Given a refresh action that itself hides the view (a pane that dismisses itself on the read).
    // When the loop runs. Then it stops after that read: 1 read, not refreshing. Red if: cancellation inside the
    // callback is ignored and the loop continues.
    @Test func hidingFromInsideTheReadStopsTheLoop() async {
        let clock = SpinClock()
        let box = RefresherBox()
        let reads = Reads()
        let refresher = VisibleRefresh(clock: clock) {
            reads.read()
            box.refresher?.setVisible(false)
        }
        box.refresher = refresher
        refresher.setVisible(true)
        await drain(500)

        #expect(reads.count == 1)
        #expect(!refresher.isRefreshing)
    }

    // OC-450-09. Given the real production clock. When visible for a moment then hidden, and more than a full interval
    // passes. Then reads stay at the one immediate read (SystemClock sleep is cancellable; nothing wakes after hide).
    // Red if: the loop outlives hide on the production clock. Real time: 2.4 s.
    @Test func realClockNothingFiresAfterHide() async throws {
        let reads = Reads()
        let refresher = VisibleRefresh { reads.read() }
        refresher.setVisible(true)
        await settle { reads.count == 1 }
        #expect(reads.count == 1)
        refresher.setVisible(false)

        try await Task.sleep(for: .milliseconds(2_400))
        #expect(reads.count == 1)
    }

    // OC-450-10. Given the real production clock and a pane left visible. When 2.4 s pass.
    // Then a second read arrived (AC 1 holds on the real clock: a change shows within one interval). Red if: the
    // production interval is longer than 2 s or the loop never re-reads.
    @Test func realClockSecondReadWithinTheInterval() async throws {
        let reads = Reads()
        let refresher = VisibleRefresh { reads.read() }
        refresher.setVisible(true)
        await settle { reads.count == 1 }
        reads.granted = true

        try await Task.sleep(for: .milliseconds(2_400))
        refresher.setVisible(false)
        #expect(reads.count == 2)
        #expect(reads.shown)
    }

    // OC-450-11. Given a VisibleRefresh dropped while still visible (a window deallocated without a hide signal).
    // When its pending sleep ends. Then the loop must not keep reading for the app's lifetime (leaked task).
    // Closed in TASK-450 re-work: deinit cancels the loop and the loop holds the owner weakly.
    @Test func droppedWhileVisibleDoesNotLeakALoop() async {
        let clock = HoldClock(), reads = Reads()
        var refresher: VisibleRefresh? = VisibleRefresh(clock: clock) { reads.read() }
        refresher?.setVisible(true)
        await settle { clock.parked == 1 }
        refresher = nil

        clock.release()
        await drain()

        #expect(reads.count == 1, "an owner that is gone must stop the loop")
        withExtendedLifetime(clock) {}
    }
}

@MainActor
private final class RefresherBox { var refresher: VisibleRefresh? }
