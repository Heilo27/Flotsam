import Foundation
import Testing
@testable import FlotsamBase

/// TASK-382 follow-up (FR-001-19, AC-001-19, ADR-0004): the delayed-resume path of `PollTick`, which reads the
/// injected clock to tell a pause and resume made in one instant from two a while apart.
///
/// Bound under test (AC-001-19): registered work keeps its period (5 s watchdog, 30 s re-resolve) between runs across
/// every pause and resume, even when they alternate faster than the period. "May run early, never late": the gap
/// between consecutive runs (the first measured from registration) never exceeds the period.
///
/// Mutation map: ignoring the clock in `creditsLostInterval` (always or never crediting) turns the delayed-resume
/// tests red; dropping the credit on resume turns the rapid-cycle tests red.
@Suite struct Worf382bResumeClockTests {
    // MARK: Harness

    private final class Time: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        var now: Double { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Double) { lock.lock(); value = newValue; lock.unlock() }
    }

    private final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        func record(_ time: Double) { lock.lock(); times.append(time); lock.unlock() }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return times }
    }

    /// Virtual-time model of the one shared timer (mirrors `ClipboardCapture.syncTimer`): re-armed from "now" only
    /// when the observed cadence changes; the fake clock handed to `PollTick` is the same virtual time.
    private final class Sim: @unchecked Sendable {
        let time = Time()
        let tick: PollTick
        private(set) var nextFire: Double?
        private var armed: Double?

        init() {
            let time = self.time
            tick = PollTick(clock: { time.now })
            tick.observeCadence { [unowned self] in self.sync() }
            sync()
        }

        var now: Double { time.now }

        private func sync() {
            let wanted = tick.cadence
            if armed == wanted, (nextFire != nil) == (wanted != nil) { return }
            armed = wanted
            nextFire = wanted.map { time.now + $0 }
        }

        func advance(by seconds: Double) {
            let target = now + seconds
            while let fire = nextFire, fire <= target + 1e-9 {
                time.set(fire)
                tick.fire()
                if nextFire == fire, let armed { nextFire = fire + armed }
            }
            time.set(target)
        }

        func advance(to target: Double) { advance(by: target - now) }
        func pause() { tick.setFastTickNeeded(false) }
        func resume() { tick.setFastTickNeeded(true) }

        /// Registers `period`-second work recording each run's virtual time.
        func register(_ period: Double) -> (runs: Runs, cancel: @Sendable () -> Void) {
            let runs = Runs()
            let time = self.time
            let cancel = tick.every(period) { runs.record(time.now) }
            return (runs, cancel)
        }
    }

    /// Longest gap between consecutive runs, the first measured from registration at 0 and the last (still pending)
    /// from the final run to `end`, so work that stopped running shows as a gap too.
    private func longestGap(_ runs: [Double], end: Double) -> Double {
        zip([0.0] + runs, runs + [end]).map { $1 - $0 }.max() ?? end
    }

    /// Slack for floating-point time only; the bound itself is the period.
    private let eps = 1e-6

    // MARK: Delayed resume

    /// AC-001-19, given the 5 s watchdog registered and capture paused mid-way through the first period, when the
    /// clock advances by a delay shorter than, equal to and longer than the 0.5 s tick (and than 5 s) before resume,
    /// then no run is ever later than 5 s after the previous one (or after registration).
    /// Red if resume skips crediting the interval lost when the timer is re-created, or reads the clock wrongly.
    @Test(arguments: [0.5, 0.75, 2.5, 4.9, 5.0, 5.1, 7.5])
    func watchdogKeepsFiveSecondBoundAcrossDelayedResume(delay: Double) {
        // given
        let sim = Sim()
        let watchdog = sim.register(5).runs
        sim.advance(to: 1.5)
        // when
        sim.pause()
        sim.advance(by: delay)
        sim.resume()
        sim.advance(to: 40)
        // then
        let runs = watchdog.all
        #expect(longestGap(runs, end: 40) <= 5.0 + eps, "delay \(delay): runs at \(runs)")
        #expect(runs.count >= 8, "delay \(delay): no starvation, expected at least 40/5 runs, got \(runs)")
        #expect(sim.tick.cadence == PollTick.interval)
    }

    /// AC-001-19, given the same pause but a delay shorter than the 0.5 s tick before resume, then the watchdog is
    /// still no later than 5 s after its previous run (FR-001-19 "keep their 5 s and 30 s bounds across every pause
    /// and resume").
    @Test(arguments: [0.25, 0.4])
    func watchdogKeepsFiveSecondBoundWhenResumedUnderOneTick(delay: Double) {
        // given
        let sim = Sim()
        let watchdog = sim.register(5).runs
        sim.advance(to: 1.5)
        // when
        sim.pause()
        sim.advance(by: delay)
        sim.resume()
        sim.advance(to: 40)
        // then
        #expect(longestGap(watchdog.all, end: 40) <= 5.0 + eps, "delay \(delay): runs at \(watchdog.all)")
    }

    /// AC-001-19, as above for the 30 s re-resolve paused at 12 s and resumed under one tick later.
    @Test(arguments: [0.25, 0.4])
    func reResolveKeepsThirtySecondBoundWhenResumedUnderOneTick(delay: Double) {
        // given
        let sim = Sim()
        let reResolve = sim.register(30).runs
        sim.advance(to: 12)
        // when
        sim.pause()
        sim.advance(by: delay)
        sim.resume()
        sim.advance(to: 200)
        // then
        #expect(longestGap(reResolve.all, end: 200) <= 30.0 + eps, "delay \(delay): runs at \(reResolve.all)")
    }

    /// AC-001-19, given only the 30 s re-resolve registered and capture paused at 12 s, when the clock advances by a
    /// delay at and above the 0.5 s tick, 5 s and 30 s before resume, then no run is later than 30 s after the
    /// previous one.
    /// Red under the same changes as the watchdog test; the 30 s period makes the lateness of a mis-credited resume
    /// larger than a tick.
    @Test(arguments: [0.5, 0.75, 5.0, 29.75, 30.0, 30.5])
    func reResolveKeepsThirtySecondBoundAcrossDelayedResume(delay: Double) {
        // given
        let sim = Sim()
        let reResolve = sim.register(30).runs
        sim.advance(to: 12)
        // when
        sim.pause()
        sim.advance(by: delay)
        sim.resume()
        sim.advance(to: 200)
        // then
        let runs = reResolve.all
        #expect(longestGap(runs, end: 200) <= 30.0 + eps, "delay \(delay): runs at \(runs)")
        #expect(runs.count >= 6, "delay \(delay): no starvation, expected at least 200/30 runs, got \(runs)")
    }

    /// AC-001-19, given capture already Paused in a slow interval (watchdog at 5 s cadence, last run at 5 s), when it
    /// resumes part-way through (2.5 s in), then the next run is no later than the original deadline of 10 s.
    /// Red if resume stretches the interval in progress.
    @Test func resumeMidSlowIntervalRunsNoLaterThanOriginalDeadline() {
        // given
        let sim = Sim()
        sim.pause()
        let watchdog = sim.register(5).runs
        sim.advance(to: 5)
        #expect(watchdog.all == [5.0])
        sim.advance(to: 7.5)
        // when
        sim.resume()
        sim.advance(to: 10)
        // then
        let runs = watchdog.all
        #expect(runs.count >= 2, "runs \(runs)")
        #expect(runs.dropFirst().first.map { $0 <= 10.0 + eps } == true, "second run at \(runs)")
    }

    /// AC-001-19, given work and a pause then resume in the same instant (clock does not move), when the clock then
    /// runs on, then the bound still holds and the work is not run twice for one interval (count stays near 40/5).
    /// Red if the same-instant guard credits one interval twice (extra runs) or drops the credit (late run).
    @Test func sameInstantPauseResumeDoesNotDoubleCreditNorStarve() {
        // given
        let sim = Sim()
        let watchdog = sim.register(5).runs
        sim.advance(to: 2.0)
        // when
        sim.pause()
        sim.resume()
        sim.advance(to: 40)
        // then
        let runs = watchdog.all
        #expect(longestGap(runs, end: 40) <= 5.0 + eps, "runs at \(runs)")
        #expect(runs.count >= 8 && runs.count <= 9, "expected 8 or 9 runs in 40 s, got \(runs)")
    }

    // MARK: Same-instant window boundary (PollTick.sameInstantWindow = 0.01 s)

    /// AC-001-19, given work paused (watchdog at 1.5 s, re-resolve at 12 s) and resumed 0.011 s later (just past the
    /// window), then the resume is credited and no run is later than its period after the previous one (strict).
    /// Red if the window is widened back toward a tick, or the credit is skipped just past the boundary.
    @Test(arguments: [(5.0, 1.5, 40.0), (30.0, 12.0, 200.0)])
    func resumeJustPastSameInstantWindowKeepsStrictBound(period: Double, pauseAt: Double, end: Double) {
        // given
        let sim = Sim()
        let work = sim.register(period).runs
        sim.advance(to: pauseAt)
        // when
        sim.pause()
        sim.advance(by: 0.011)
        sim.resume()
        sim.advance(to: end)
        // then
        let runs = work.all
        #expect(longestGap(runs, end: end) <= period + eps, "period \(period): runs at \(runs)")
        #expect(runs.count >= Int(end / period) - 1, "period \(period): runs \(runs)")
    }

    /// AC-001-19, given work paused and resumed exactly 0.01 s later (the window itself: whether it counts as the same
    /// instant depends on float rounding of the clock reads), then the lateness is at most the window (10 ms, inside
    /// the 100 ms tolerance of FR-001-01) and the work still runs every period.
    /// Red if the window grows beyond 10 ms or the boundary loses more than the window.
    @Test(arguments: [(5.0, 1.5, 40.0), (30.0, 12.0, 200.0)])
    func resumeAtSameInstantWindowLosesAtMostTheWindow(period: Double, pauseAt: Double, end: Double) {
        // given
        let sim = Sim()
        let work = sim.register(period).runs
        sim.advance(to: pauseAt)
        // when
        sim.pause()
        sim.advance(by: 0.01)
        sim.resume()
        sim.advance(to: end)
        // then
        let runs = work.all
        #expect(longestGap(runs, end: end) <= period + 0.01 + eps, "period \(period): runs at \(runs)")
        #expect(runs.count >= Int(end / period) - 1, "period \(period): runs \(runs)")
    }

    /// AC-001-19, given the watchdog registered at 0 s (original alignment: due at 5 s) and capture paused at 1.5 s,
    /// when it resumes 4.9 s later (6.4 s), then the first run is at or before 5 s and later runs never more than 5 s
    /// apart; the watchdog is never pushed later by the pause.
    /// Red if resume re-bases the watchdog from the resume time (first run would land after 5 s).
    @Test func watchdogResumedAfterFourPointNineSecondsStillFiresByOriginalDeadline() {
        // given
        let sim = Sim()
        let watchdog = sim.register(5).runs
        sim.advance(to: 1.5)
        // when
        sim.pause()
        sim.advance(by: 4.9)
        sim.resume()
        sim.advance(to: 40)
        // then
        let runs = watchdog.all
        #expect(runs.first.map { $0 <= 5.0 + eps } == true, "first run must be by 5 s, runs \(runs)")
        #expect(longestGap(runs, end: 40) <= 5.0 + eps, "runs at \(runs)")
        #expect(runs.count >= 8, "runs \(runs)")
    }

    /// AC-001-19, given the watchdog and re-resolve registered and capture cycling Paused/Active with phases just
    /// around the same-instant window (0.005 s inside, 0.011 and 0.02 s outside), when run for 120 s, then neither
    /// bound is exceeded (inside the window: by no more than the window per run) and neither starves.
    /// Red if repeated sub-tick cycles each lose time that is never credited (watchdog starves or drifts late).
    @Test(arguments: [0.005, 0.011, 0.02])
    func rapidSubTickCyclesDoNotStarveWatchdog(step: Double) {
        // given
        let sim = Sim()
        let watchdog = sim.register(5).runs
        let reResolve = sim.register(30).runs
        // when
        var paused = false
        while sim.now < 120 {
            if paused { sim.resume() } else { sim.pause() }
            paused.toggle()
            sim.advance(by: step)
        }
        if paused { sim.resume() }
        let end = sim.now
        // then
        let slack = step < 0.01 ? 0.01 : eps
        #expect(longestGap(watchdog.all, end: end) <= 5.0 + slack, "step \(step): watchdog at \(watchdog.all)")
        #expect(longestGap(reResolve.all, end: end) <= 30.0 + slack, "step \(step): re-resolve at \(reResolve.all)")
        #expect(watchdog.all.count >= 24, "step \(step): watchdog starved: \(watchdog.all.count) runs")
        #expect(reResolve.all.count >= 4, "step \(step): re-resolve starved: \(reResolve.all.count) runs")
    }

    // MARK: Rapid cycling

    /// AC-001-19, given both periods registered and capture alternating Paused and Active with the clock advancing a
    /// little each cycle (never reaching a tick), when run for 120 s, then registered work still advances: neither
    /// period is exceeded and neither starves.
    /// Red if the credit on a cadence change is dropped (timer re-created each cycle never fires).
    @Test(arguments: [0.1, 0.2, 0.3, 0.45])
    func rapidCyclingBelowOneTickKeepsBoundsNoStarvation(step: Double) {
        // given
        let sim = Sim()
        let watchdog = sim.register(5).runs
        let reResolve = sim.register(30).runs
        // when
        var paused = false
        while sim.now < 120 {
            if paused { sim.resume() } else { sim.pause() }
            paused.toggle()
            sim.advance(by: step)
        }
        if paused { sim.resume() }
        let end = sim.now
        // then
        #expect(longestGap(watchdog.all, end: end) <= 5.0 + eps, "step \(step): watchdog at \(watchdog.all)")
        #expect(longestGap(reResolve.all, end: end) <= 30.0 + eps, "step \(step): re-resolve at \(reResolve.all)")
        #expect(watchdog.all.count >= 24, "step \(step): watchdog starved: \(watchdog.all.count) runs")
        #expect(reResolve.all.count >= 4, "step \(step): re-resolve starved: \(reResolve.all.count) runs")
    }

    /// AC-001-19, given the same alternation but with each phase lasting longer than one tick (0.6 s, 1.7 s, 6 s),
    /// when run for 120 s, then the bounds hold and nothing starves.
    /// Red if a firing between changes is mis-counted so a period stretches.
    @Test(arguments: [0.6, 1.7, 6.0])
    func rapidCyclingAboveOneTickKeepsBoundsNoStarvation(step: Double) {
        // given
        let sim = Sim()
        let watchdog = sim.register(5).runs
        let reResolve = sim.register(30).runs
        // when
        var paused = false
        while sim.now < 120 {
            if paused { sim.resume() } else { sim.pause() }
            paused.toggle()
            sim.advance(by: step)
        }
        if paused { sim.resume() }
        let end = sim.now
        // then
        #expect(longestGap(watchdog.all, end: end) <= 5.0 + eps, "step \(step): watchdog at \(watchdog.all)")
        #expect(longestGap(reResolve.all, end: end) <= 30.0 + eps, "step \(step): re-resolve at \(reResolve.all)")
        #expect(watchdog.all.count >= 24, "step \(step): watchdog starved: \(watchdog.all.count) runs")
        #expect(reResolve.all.count >= 4, "step \(step): re-resolve starved: \(reResolve.all.count) runs")
    }
}
