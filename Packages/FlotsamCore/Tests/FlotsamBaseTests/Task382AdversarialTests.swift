import Foundation
import Testing
@testable import FlotsamBase

/// TASK-382 adversarial QA (FR-001-19, AC-001-19, ADR-0004, FR-007-12, AC-007-10) for `PollTick`.
///
/// The author's tests advance virtual time only in whole firings of the reported cadence, so a pause or resume always
/// lands on a timer boundary. The real timer (`ClipboardCapture.syncTimer`) is re-created at the moment the cadence
/// changes and its first firing is a full new interval later, so a change can land anywhere inside an interval.
/// `Sim` mirrors that: virtual wall time, one timer re-armed (from "now") only when the observed cadence changes.
@Suite struct Task382AdversarialTests {
    // MARK: Harness

    private final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        func record(_ time: Double) { lock.lock(); times.append(time); lock.unlock() }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return times }
        var count: Int { all.count }
    }

    /// Virtual-time model of the one shared timer, mirroring `ClipboardCapture.syncTimer`: rescheduled from `now` only
    /// when `cadence` changes; nil cadence means no timer.
    private final class Sim: @unchecked Sendable {
        let tick = PollTick()
        var now = 0.0
        private(set) var nextFire: Double?
        private var armed: Double?
        private(set) var rearms = 0

        init() {
            tick.observeCadence { [unowned self] in self.sync() }
            sync()
        }

        private func sync() {
            let wanted = tick.cadence
            if armed == wanted, (nextFire != nil) == (wanted != nil) { return }
            armed = wanted
            nextFire = wanted.map { now + $0 }
            rearms += 1
        }

        func advance(by seconds: Double) {
            let target = now + seconds
            while let fire = nextFire, fire <= target + 1e-9 {
                now = fire
                tick.fire()
                if nextFire == fire, let armed { nextFire = fire + armed }
            }
            now = target
        }

        func pause() { tick.setFastTickNeeded(false) }
        func resume() { tick.setFastTickNeeded(true) }
    }

    private func longestGap(_ runs: [Double], from start: Double = 0, end: Double) -> Double {
        zip([start] + runs, runs + [end]).map { $1 - $0 }.max() ?? (end - start)
    }

    // MARK: Co-prime and odd periods

    /// given consumers of 1.5 s (3 ticks) and 2.5 s (5 ticks), whose gcd is one tick, when capture is Paused, then the
    /// timer stays at 0.5 s (nothing coarser divides both) and each runs on exactly its own multiples.
    /// Red if: the cadence is computed as an lcm, min or max instead of the gcd.
    @Test func coPrimePeriodsKeepTheFinestCadenceWhilePaused() {
        let sim = Sim()
        let a = Runs(), b = Runs()
        _ = sim.tick.every(1.5) { a.record(sim.now) }
        _ = sim.tick.every(2.5) { b.record(sim.now) }
        sim.pause()
        #expect(sim.tick.cadence == 0.5)
        sim.advance(by: 15)
        #expect(a.all == [1.5, 3, 4.5, 6, 7.5, 9, 10.5, 12, 13.5, 15])
        #expect(b.all == [2.5, 5, 7.5, 10, 12.5, 15])
    }

    /// given consumers of 2 s (4 ticks) and 3 s (6 ticks), gcd two ticks, when Paused, then the timer is 1 s and the
    /// runs land on exactly 2, 4, 6... and 3, 6, 9... (neither slips to a neighbouring firing).
    @Test func commonFactorOfTwoTicksGivesAOneSecondCadence() {
        let sim = Sim()
        let a = Runs(), b = Runs()
        _ = sim.tick.every(2) { a.record(sim.now) }
        _ = sim.tick.every(3) { b.record(sim.now) }
        sim.pause()
        #expect(sim.tick.cadence == 1)
        sim.advance(by: 12)
        #expect(a.all == [2, 4, 6, 8, 10, 12])
        #expect(b.all == [3, 6, 9, 12])
    }

    /// given 3.5 s (7 ticks) and 5.5 s (11 ticks), when Paused, then 0.5 s and each runs on its own multiples; the
    /// shared multiple (38.5 s) runs both on one firing.
    @Test func largeCoPrimePeriods() {
        let sim = Sim()
        let a = Runs(), b = Runs()
        _ = sim.tick.every(3.5) { a.record(sim.now) }
        _ = sim.tick.every(5.5) { b.record(sim.now) }
        sim.pause()
        #expect(sim.tick.cadence == 0.5)
        sim.advance(by: 40)
        #expect(a.all == [3.5, 7, 10.5, 14, 17.5, 21, 24.5, 28, 31.5, 35, 38.5])
        #expect(b.all == [5.5, 11, 16.5, 22, 27.5, 33, 38.5])
    }

    /// Periods that do not land on a tick round to the nearest whole tick, minimum one (0 and negative included).
    /// Red if: the rounding or the floor of one tick changes.
    @Test func periodsRoundToWholeTicksWithAFloorOfOne() {
        let tick = PollTick()
        tick.setFastTickNeeded(false)
        let c1 = tick.every(0.74) {}   // 1.48 ticks -> 1
        #expect(tick.cadence == 0.5)
        c1()
        #expect(tick.cadence == nil)
        let c2 = tick.every(0.75) {}   // 1.5 ticks -> 2
        #expect(tick.cadence == 1)
        c2()
        let c3 = tick.every(0) {}
        #expect(tick.cadence == 0.5, "zero seconds is one tick")
        c3()
        let c4 = tick.every(-3) {}
        #expect(tick.cadence == 0.5, "negative seconds is one tick")
        c4()
        #expect(tick.registrationCount == 0)
    }

    // MARK: Consumers registered and cancelled while Paused

    /// given Paused with only the 30 s re-resolve, when the 5 s watchdog registers, then the cadence goes to 5 s;
    /// when it cancels it returns to 30 s; when the last consumer cancels the cadence is nil and the observer hears it.
    /// Red if: a change in the registered set while Paused does not re-derive the cadence or skip the observer.
    @Test func registeringAndCancellingWhilePausedRetunesAndNotifies() {
        final class Heard: @unchecked Sendable { var n = 0 }
        let tick = PollTick()
        let heard = Heard()
        tick.observeCadence { heard.n += 1 }
        tick.setFastTickNeeded(false)
        #expect(heard.n == 1)
        let cancelResolve = tick.every(30) {}
        #expect(tick.cadence == 30)
        #expect(heard.n == 2)
        let cancelWatchdog = tick.every(5) {}
        #expect(tick.cadence == 5)
        #expect(heard.n == 3)
        cancelWatchdog()
        #expect(tick.cadence == 30)
        #expect(heard.n == 4)
        cancelResolve()
        #expect(tick.cadence == nil)
        #expect(heard.n == 5)
        #expect(tick.registrationCount == 0)
    }

    /// given a cancel closure called twice, when the second call runs, then nothing changes: no second observer call,
    /// and a different consumer's registration is untouched (ids are never reused).
    /// Red if: cancel removes by position or value, or notifies on a no-op.
    @Test func cancellingTwiceIsANoOp() {
        final class Heard: @unchecked Sendable { var n = 0 }
        let tick = PollTick()
        let heard = Heard()
        tick.setFastTickNeeded(false)
        let first = tick.every(5) {}
        let second = tick.every(30) {}
        tick.observeCadence { heard.n += 1 }
        first()
        #expect(tick.cadence == 30)
        #expect(heard.n == 1)
        first()
        #expect(heard.n == 1)
        #expect(tick.registrationCount == 1)
        #expect(tick.cadence == 30)
        second()
        #expect(tick.cadence == nil)
        #expect(tick.registrationCount == 0)
    }

    /// given Paused with no consumers (no timer), when `fire()` is called anyway and a consumer then registers, then
    /// nothing ran spuriously, and the new consumer's first run is one full period (5 s) after it registered.
    /// Red if: a stray firing runs work that is not registered, or registration runs the new work inside `every`.
    @Test func lastConsumerCancelledThenAnotherRegisteredWhilePaused() {
        let sim = Sim()
        sim.pause()
        #expect(sim.tick.cadence == nil)
        sim.advance(by: 7.3)
        let ran = Runs()
        _ = sim.tick.every(5) { ran.record(sim.now) }
        #expect(ran.count == 0, "not run inside every")
        sim.advance(by: 5.0001)
        #expect(ran.all.count == 1)
        #expect(abs(ran.all[0] - (7.3 + 5)) < 0.0001, "first run a full period after registering: \(ran.all)")
    }

    /// given Paused with the watchdog, when a 0.5 s consumer registers, then the cadence returns to 0.5 s and the
    /// 0.5 s consumer runs on every firing; when it cancels the cadence is 5 s again.
    /// Red if: a remaining 0.5 s consumer is ignored when the poll itself stops needing the tick.
    @Test func halfSecondConsumerJoiningAndLeavingWhilePaused() {
        let sim = Sim()
        let watchdog = Runs(), fast = Runs()
        _ = sim.tick.every(5) { watchdog.record(sim.now) }
        sim.pause()
        sim.advance(by: 10)
        let cancelFast = sim.tick.every(0.5) { fast.record(sim.now) }
        #expect(sim.tick.cadence == 0.5)
        sim.advance(by: 2)
        #expect(fast.all == [10.5, 11, 11.5, 12])
        cancelFast()
        #expect(sim.tick.cadence == 5)
    }

    /// given a consumer that cancels itself and registers a replacement from inside `fire()` while Paused, when the
    /// tick fires, then there is no deadlock, the old work ran once, the replacement runs on its own period, and the
    /// cadence is the replacement's.
    /// Red if: `fire()` or `change` held the lock while running work.
    @Test(.timeLimit(.minutes(1))) func workMayCancelAndRegisterFromInsideFire() {
        let sim = Sim()
        sim.pause()
        let old = Runs(), replacement = Runs()
        final class Box: @unchecked Sendable { var cancel: (@Sendable () -> Void)? }
        let box = Box()
        box.cancel = sim.tick.every(5) {
            old.record(sim.now)
            box.cancel?()
            _ = sim.tick.every(30) { replacement.record(sim.now) }
        }
        sim.advance(by: 5)
        #expect(old.all == [5])
        #expect(sim.tick.cadence == 30)
        #expect(sim.tick.registrationCount == 1)
        sim.advance(by: 100)
        #expect(old.count == 1)
        #expect(replacement.count >= 3)
    }

    // MARK: Pause / resume racing ticks

    /// given Paused and the watchdog/re-resolve registered, when capture rapidly goes pause, resume, pause with no
    /// time between, then the cadence ends at 5 s, the observer was told once per real change, and the watchdog ran at
    /// most once for the aligned boundary (no duplicate run per toggle at an aligned count).
    /// Red if: a toggle at an aligned count runs due work again, or a toggle skips the observer.
    @Test func rapidPauseResumePauseAtOneInstant() {
        final class Heard: @unchecked Sendable { var n = 0 }
        let tick = PollTick()
        let heard = Heard()
        let watchdog = Runs()
        _ = tick.every(5) { watchdog.record(0) }
        _ = tick.every(30) {}
        for _ in 0..<7 { tick.fire() }   // count 7: mid-period
        tick.observeCadence { heard.n += 1 }
        tick.setFastTickNeeded(false)
        tick.setFastTickNeeded(true)
        tick.setFastTickNeeded(false)
        #expect(tick.cadence == 5)
        #expect(heard.n == 3)
        #expect(watchdog.count == 1, "one aligned boundary crossing, not one per toggle: \(watchdog.count)")
    }

    /// given a stale 0.5 s timer firing once after the cadence was already slowed (the observer hops to the main actor,
    /// so one old-interval firing can land after the change), when it fires, then work runs early at worst, never late
    /// and never more than once per period boundary crossed.
    /// Red if: a firing at the wrong cadence double-runs work or drops a boundary.
    @Test func staleFastFiringAfterThePauseOnlyRunsWorkEarly() {
        let tick = PollTick()
        let watchdog = Runs()
        final class T: @unchecked Sendable { var v = 0.0 }
        let t = T()
        _ = tick.every(5) { watchdog.record(t.v) }
        tick.setFastTickNeeded(false)       // count 0 aligned, step 10
        t.v = 0.5; tick.fire()                // stale firing: count 10, crosses the watchdog boundary at once
        #expect(watchdog.all == [0.5])
        t.v = 5.5; tick.fire()                // next real slow firing
        #expect(watchdog.all == [0.5, 5.5])
    }

    /// given threads firing, toggling and registering concurrently, when they finish, then there is no deadlock or
    /// crash, and the final state is exactly what the last operations left (consistent cadence, no leaked entries).
    /// Red if: the state lock is dropped between reading `step` and mutating the count.
    @Test(.timeLimit(.minutes(2))) func concurrentFireToggleAndRegistrationSettlesConsistently() async {
        let tick = PollTick()
        let ran = Runs()
        let watchdog = tick.every(5) { ran.record(0) }
        await withTaskGroup(of: Void.self) { group in
            for lane in 0..<4 {
                group.addTask {
                    for i in 0..<3000 {
                        switch (lane + i) % 4 {
                        case 0: tick.fire()
                        case 1: tick.setFastTickNeeded(i % 2 == 0)
                        case 2:
                            let cancel = tick.every(Double(1 + i % 7) * 0.5) { ran.record(1) }
                            cancel()
                        default: _ = tick.cadence
                        }
                    }
                }
            }
        }
        tick.setFastTickNeeded(false)
        #expect(tick.registrationCount == 1, "only the watchdog is left")
        #expect(tick.cadence == 5)
        watchdog()
        #expect(tick.registrationCount == 0)
        #expect(tick.cadence == nil)
        tick.setFastTickNeeded(true)
        #expect(tick.cadence == 0.5)
        #expect(ran.count > 0)
    }

    // MARK: Real-time bounds (changes landing mid-interval)

    /// given Paused with the watchdog and the re-resolve, when capture resumes part-way through a 5 s interval, then
    /// the watchdog still runs within 5 s of its previous run (AC-001-19, FR-005-19). The elapsed part of the slow
    /// interval is not credited to the count when the timer is re-created, so the watchdog's next run slips by it.
    /// Red when: resume mid-interval stretches the watchdog past 5 s. FAILS on 14c52e4 (see W382-D1).
    @Test(arguments: [0.5, 2.5, 4.9])
    func watchdogBoundHoldsWhenResumeLandsMidSlowInterval(resumeAfter: Double) {
        let sim = Sim()
        let watchdog = Runs()
        _ = sim.tick.every(5) { watchdog.record(sim.now) }
        _ = sim.tick.every(30) {}
        sim.advance(by: 10)
        sim.pause()
        sim.advance(by: resumeAfter)
        sim.resume()
        sim.advance(by: 30)
        #expect(longestGap(watchdog.all, end: sim.now) <= 5.0001, "watchdog runs: \(watchdog.all)")
    }

    /// given Paused with only the 30 s re-resolve registered, when capture resumes 29.5 s into the 30 s interval, then
    /// the re-resolve still runs within 30 s of its previous run (FR-002-02).
    /// Red when: the unsent part of the slow interval stretches the re-resolve. FAILS on 14c52e4 (see W382-D1).
    @Test func resolveBoundHoldsWhenResumeLandsMidSlowInterval() {
        let sim = Sim()
        let resolve = Runs()
        _ = sim.tick.every(30) { resolve.record(sim.now) }
        sim.advance(by: 30)             // runs at 30
        sim.pause()
        sim.advance(by: 29.5)           // timer due at 60, resume just before
        sim.resume()
        sim.advance(by: 60)
        #expect(longestGap(resolve.all, end: sim.now) <= 30.0001, "re-resolve runs: \(resolve.all)")
    }

    /// given a user toggling Paused and Active quickly (Paused 4.9 s, Active 0.4 s, repeat), when 100 s pass, then the
    /// watchdog still runs within its 5 s bound. The timer is re-created at every change and no interval ever
    /// completes, so the count never advances and the watchdog is starved.
    /// Red when: repeated mid-interval changes starve registered work. FAILS on 14c52e4 (see W382-D2).
    @Test func rapidPauseResumeCyclingDoesNotStarveTheWatchdog() {
        let sim = Sim()
        let watchdog = Runs()
        _ = sim.tick.every(5) { watchdog.record(sim.now) }
        sim.advance(by: 5)
        for _ in 0..<19 {
            sim.pause()
            sim.advance(by: 4.9)
            sim.resume()
            sim.advance(by: 0.4)
        }
        #expect(longestGap(watchdog.all, end: sim.now) <= 5.0001, "runs: \(watchdog.all)")
    }

    /// Control for the two above: a pause landing mid fast interval stretches the watchdog by the uncounted part of
    /// that 0.5 s interval at most (observed 0.1 to 0.3 s over the 5 s bound; Minor, see W382-D1 note), never more.
    /// Red if: the pause alignment stops running work that falls due in the gap (the gap would reach 5.5 s or more).
    @Test(arguments: [0.1, 0.3, 2.2, 4.8])
    func watchdogBoundHoldsWhenPauseLandsMidFastInterval(pauseAfter: Double) {
        let sim = Sim()
        let watchdog = Runs(), resolve = Runs()
        _ = sim.tick.every(5) { watchdog.record(sim.now) }
        _ = sim.tick.every(30) { resolve.record(sim.now) }
        sim.advance(by: 10 + pauseAfter)
        sim.pause()
        sim.advance(by: 120)
        #expect(longestGap(watchdog.all, end: sim.now) < 5.5, "watchdog runs: \(watchdog.all)")
        #expect(longestGap(resolve.all, end: sim.now) < 30.5, "re-resolve runs: \(resolve.all)")
        #expect(sim.tick.cadence == 5)
    }

    /// One timer only: while Paused with consumers the model's timer is a single schedule at the reported cadence, and
    /// the simulated timer is only re-armed when the cadence changes (no re-arm for an unchanged cadence).
    /// Red if: a no-change toggle re-arms (restarting the interval and delaying work).
    @Test func unchangedCadenceDoesNotReArmTheTimer() {
        let sim = Sim()
        _ = sim.tick.every(5) {}
        let base = sim.rearms
        sim.tick.setFastTickNeeded(true)    // already true
        #expect(sim.rearms == base)
        sim.pause()
        #expect(sim.rearms == base + 1)
        sim.pause()
        #expect(sim.rearms == base + 1)
    }
}
