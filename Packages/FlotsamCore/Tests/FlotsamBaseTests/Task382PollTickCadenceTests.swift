import Foundation
import Testing
@testable import FlotsamBase

/// TASK-382 (FR-001-19, ADR-0004): `PollTick` owns the cadence. While the pasteboard poll does not need the 0.5 s
/// tick it slows to the coarsest cadence the registered work needs, and the work keeps its period bounds. Time here is
/// virtual: each `fire()` advances the clock by the cadence the tick reports, so nothing sleeps.
@Suite struct Task382PollTickCadenceTests {
    private final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        func record(_ time: Double) { lock.lock(); times.append(time); lock.unlock() }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return times }
        var count: Int { all.count }
    }

    private final class Clock: @unchecked Sendable {
        var now = 0.0
    }

    /// Largest gap between consecutive runs, counting the start (0) and the end of the timeline.
    private func longestGap(_ runs: [Double], end: Double) -> Double {
        zip([0.0] + runs, runs + [end]).map { $1 - $0 }.max() ?? end
    }

    @Test func cadenceDefaultsToHalfASecondAndFollowsTheRemainingConsumers() {
        let tick = PollTick()
        #expect(tick.cadence == 0.5, "default: the poll needs the 0.5 s tick")

        _ = tick.every(5) {}
        let cancelResolve = tick.every(30) {}
        #expect(tick.cadence == 0.5)

        tick.setFastTickNeeded(false)
        #expect(tick.cadence == 5, "paused with the watchdog and the re-resolve: 5 s")
        cancelResolve()
        #expect(tick.cadence == 5)

        tick.setFastTickNeeded(true)
        #expect(tick.cadence == 0.5, "resume restores 0.5 s")
    }

    @Test func pausedCadenceIsTheCoarsestOneEveryRemainingPeriodDivides() {
        let tick = PollTick()
        tick.setFastTickNeeded(false)
        #expect(tick.cadence == nil, "nothing registered: no firing needed")

        let cancelThirty = tick.every(30) {}
        #expect(tick.cadence == 30)
        let cancelFive = tick.every(5) {}
        #expect(tick.cadence == 5)
        cancelFive()
        #expect(tick.cadence == 30)
        cancelThirty()
        #expect(tick.cadence == nil)
    }

    @Test func aHalfSecondConsumerKeepsTheHalfSecondTickEvenWhilePaused() {
        let tick = PollTick()
        _ = tick.every(5) {}
        _ = tick.every(0.5) {}
        tick.setFastTickNeeded(false)
        #expect(tick.cadence == 0.5, "a remaining 0.5 s consumer still needs 0.5 s")
    }

    @Test func theObserverHearsEachCadenceChangeAndOnlyThose() {
        final class Heard: @unchecked Sendable { var n = 0 }
        let tick = PollTick()
        let heard = Heard()
        tick.observeCadence { heard.n += 1 }
        let cancel = tick.every(5) {}
        #expect(heard.n == 0, "fast: 0.5 s before and after")
        tick.setFastTickNeeded(false)
        #expect(heard.n == 1)
        tick.setFastTickNeeded(false)
        #expect(heard.n == 1, "no change, no call")
        cancel()
        #expect(heard.n == 2, "nothing left: cadence is nil")
        tick.setFastTickNeeded(true)
        #expect(heard.n == 3)
    }

    /// The watchdog (5 s, FR-005-19) and the re-resolve (30 s, FR-002-02) run within their bounds across a pause that
    /// starts in the middle of a period, a long pause, and a resume in the middle of a period.
    @Test(arguments: [3, 7, 10, 13, 19])
    func workKeepsItsBoundsAcrossPauseAndResume(fastTicksBeforePause: Int) {
        let tick = PollTick()
        let clock = Clock()
        let watchdog = Runs(), resolve = Runs()
        _ = tick.every(5) { watchdog.record(clock.now) }
        _ = tick.every(30) { resolve.record(clock.now) }

        func advance(whileCadenceIs expected: Double, until end: Double) {
            while clock.now < end - 0.0001 {
                guard let cadence = tick.cadence else { Issue.record("no cadence"); return }
                #expect(cadence == expected)
                clock.now += cadence
                tick.fire()
            }
        }

        advance(whileCadenceIs: 0.5, until: Double(fastTicksBeforePause) * 0.5)
        tick.setFastTickNeeded(false)
        let pausedFrom = clock.now
        advance(whileCadenceIs: 5, until: pausedFrom + 100)
        let sinceFast = clock.now
        // Resume in the middle of a period.
        tick.setFastTickNeeded(true)
        advance(whileCadenceIs: 0.5, until: sinceFast + 41.5)

        let end = clock.now
        #expect(longestGap(watchdog.all, end: end) <= 5.0001, "watchdog gaps: \(watchdog.all)")
        #expect(longestGap(resolve.all, end: end) <= 30.0001, "re-resolve gaps: \(resolve.all)")
        #expect(watchdog.count >= Int(end / 5) - 1)
    }

    /// Dropping the watchdog while paused coarsens the cadence to 30 s; the re-resolve must still run within 30 s of
    /// its previous run even though the count was not on a 30 s boundary.
    @Test func cancellingWorkWhilePausedDoesNotStretchTheRemainingPeriod() {
        let tick = PollTick()
        let clock = Clock()
        let resolve = Runs()
        let cancelWatchdog = tick.every(5) {}
        _ = tick.every(30) { resolve.record(clock.now) }
        tick.setFastTickNeeded(false)
        for _ in 0..<3 { clock.now += tick.cadence ?? 0; tick.fire() }
        cancelWatchdog()
        #expect(tick.cadence == 30)
        while clock.now < 200 { clock.now += tick.cadence ?? 0; tick.fire() }

        #expect(longestGap(resolve.all, end: clock.now) <= 30.0001, "gaps: \(resolve.all)")
    }

    @Test func workRegisteredWhilePausedDoesNotRunInsideRegistration() {
        let tick = PollTick()
        tick.setFastTickNeeded(false)
        _ = tick.every(30) {}
        let ran = Runs()
        // 5 s joins a 30 s cadence: the new work is not run from inside `every`, only from a later firing.
        _ = tick.every(5) { ran.record(0) }
        #expect(ran.count == 0)
        #expect(tick.cadence == 5)
        tick.fire()
        #expect(ran.count == 1)
    }
}
