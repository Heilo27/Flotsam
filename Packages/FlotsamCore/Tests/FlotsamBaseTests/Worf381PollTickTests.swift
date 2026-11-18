import Foundation
import Testing
@testable import FlotsamBase

/// TASK-381 (S5, ADR-0004): `PollTick` is the one shared tick. Every test drives `fire()` directly; nothing sleeps.
@Suite struct Worf381PollTickTests {
    /// A thread-safe counter the registered work bumps (the work closure is `@Sendable`).
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func fire(_ tick: PollTick, _ times: Int) { for _ in 0..<times { tick.fire() } }

    // MARK: The Nth-tick math

    /// OC-381-01. given work registered every 5 s and every 30 s, when 59 ticks fire, then the 5 s work ran 5 times
    /// (ticks 10..50) and the 30 s work not at all; the 60th tick runs the 30 s work once and the 5 s work a sixth
    /// time. Red if the divisor changes (period/interval) or the modulo is off by one (`count % n == 1`, `> n`).
    @Test func fiveAndThirtySecondWorkRunOnTheTenthAndSixtiethTick() {
        let tick = PollTick()
        let five = Count(), thirty = Count()
        _ = tick.every(5) { five.bump() }
        _ = tick.every(30) { thirty.bump() }

        fire(tick, 9)
        #expect(five.value == 0, "no run before the 10th tick")
        tick.fire()
        #expect(five.value == 1, "runs on exactly the 10th tick")
        fire(tick, 49)
        #expect(five.value == 5)
        #expect(thirty.value == 0, "no run before the 60th tick")
        tick.fire()
        #expect(thirty.value == 1)
        #expect(five.value == 6)
    }

    /// OC-381-02. boundary: a period shorter than, equal to and not a multiple of the interval. given every(0),
    /// every(-5), every(0.5) then each runs on every tick (at least one); every(0.74) rounds to 1 tick, every(0.75)
    /// to 2 ticks, every(5.2) to 10. Red if the `max(1, ...)` floor or the rounding is dropped (a 0 divisor traps).
    @Test(arguments: [(0.0, 1), (-5.0, 1), (0.5, 1), (0.74, 1), (0.75, 2), (5.2, 10)])
    func periodsRoundToWholeTicksWithAFloorOfOne(seconds: Double, expectedTicks: Int) {
        let tick = PollTick()
        let count = Count()
        _ = tick.every(seconds) { count.bump() }

        fire(tick, expectedTicks * 3)

        #expect(count.value == 3, "\(seconds) s should run every \(expectedTicks) tick(s)")
    }

    /// OC-381-03. given 1000 fire() calls spread over 8 threads, when the work is every(1) and every(2), then it ran
    /// exactly 1000 and 500 times: the shared counter is atomic (a lost increment changes both numbers).
    @Test func concurrentFiresNeitherLoseNorDoubleATick() async {
        let tick = PollTick()
        let every = Count(), second = Count()
        _ = tick.every(0.5) { every.bump() }
        _ = tick.every(1) { second.bump() }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { for _ in 0..<125 { tick.fire() } } }
        }

        #expect(every.value == 1000)
        #expect(second.value == 500)
    }

    /// OC-381-04. given work, when fire() returns, then the work has already run (the synchronous contract the
    /// callers rely on: they only spawn a Task inside it). Red if fire() hands the work to another queue.
    @Test func dueWorkHasRunBeforeFireReturns() {
        let tick = PollTick()
        let count = Count()
        _ = tick.every(0.5) { count.bump() }
        tick.fire()
        #expect(count.value == 1)
    }

    // MARK: Registration and cancellation

    /// OC-381-05. given three registrations and one cancelled, then registrationCount goes 3 -> 2, the cancelled work
    /// never runs again and its two siblings keep their identity and cadence. Red if cancel removes the wrong entry
    /// or all of them, or does nothing.
    @Test func cancellingOneRegistrationLeavesTheOthersRunning() {
        let tick = PollTick()
        let a = Count(), b = Count(), c = Count()
        _ = tick.every(0.5) { a.bump() }
        let cancelB = tick.every(0.5) { b.bump() }
        _ = tick.every(0.5) { c.bump() }
        #expect(tick.registrationCount == 3)

        fire(tick, 2)
        cancelB()
        fire(tick, 3)

        #expect(tick.registrationCount == 2)
        #expect((a.value, b.value, c.value) == (5, 2, 5))
    }

    /// OC-381-06. given the last registration cancelled, then registrationCount is 0 and further ticks run nothing
    /// (the ScreenshotWatcher test asserts "nothing left registered" through this number).
    @Test func cancellingTheOnlyRegistrationEmptiesTheTick() {
        let tick = PollTick()
        let count = Count()
        let cancel = tick.every(0.5) { count.bump() }
        cancel()
        fire(tick, 10)
        #expect(tick.registrationCount == 0)
        #expect(count.value == 0)
    }

    /// OC-381-07. given a cancel closure called twice, and a new registration made after the first cancel, then the
    /// stale closure must not cancel the newcomer (ids are never reused). Red if ids restart or are recycled, which
    /// is what a stop/start of the engine or watcher does.
    @Test func aStaleCancelClosureDoesNotRemoveALaterRegistration() {
        let tick = PollTick()
        let old = Count(), fresh = Count()
        let cancelOld = tick.every(0.5) { old.bump() }
        cancelOld()
        _ = tick.every(0.5) { fresh.bump() }

        cancelOld()
        cancelOld()
        fire(tick, 4)

        #expect(tick.registrationCount == 1)
        #expect(old.value == 0)
        #expect(fresh.value == 4)
    }

    /// OC-381-08. re-registration: given the same work registered, cancelled and registered again 3 times (the
    /// watcher's deactivate/activate cycle), then exactly one registration is live and one tick runs the work once,
    /// not once per past registration.
    @Test func reRegisteringDoesNotAccumulateRuns() {
        let tick = PollTick()
        let count = Count()
        var cancel = tick.every(0.5) { count.bump() }
        for _ in 0..<3 {
            cancel()
            cancel = tick.every(0.5) { count.bump() }
        }
        #expect(tick.registrationCount == 1)

        tick.fire()

        #expect(count.value == 1)
    }

    /// OC-381-09. cancellation during fire: given work that cancels itself on its first run, then it ran once, never
    /// again, and a sibling due on the same ticks is unaffected. Red if fire() holds the lock while running work
    /// (the cancel would deadlock) or if self-cancel is ignored.
    @Test func workMayCancelItselfInsideFire() {
        let tick = PollTick()
        let selfCancelling = Count(), sibling = Count()
        let box = CancelBox()
        box.cancel = tick.every(0.5) {
            selfCancelling.bump()
            box.cancel?()
        }
        _ = tick.every(0.5) { sibling.bump() }

        fire(tick, 4)

        #expect(selfCancelling.value == 1)
        #expect(sibling.value == 4)
        #expect(tick.registrationCount == 1)
    }

    /// OC-381-10. cancellation during fire, of a peer: given A (registered first or not) cancels B on the same tick B
    /// is due, then from the NEXT tick B never runs. (B may run once on the tick being fired, because due work is
    /// snapshotted before any runs; callers guard with `active` / `[weak self]` for that, see OC-381-13.)
    @Test func aPeerCancelledDuringAFireNeverRunsOnALaterTick() {
        let tick = PollTick()
        let victim = Count()
        let cancelVictim = tick.every(0.5) { victim.bump() }
        _ = tick.every(0.5) { cancelVictim() }

        tick.fire()
        let afterFirst = victim.value
        fire(tick, 5)

        #expect(afterFirst <= 1)
        #expect(victim.value == afterFirst, "no run after the tick that cancelled it")
        #expect(tick.registrationCount == 1)
    }

    /// OC-381-11. registration during fire: given work that registers more work on its first run, then there is no
    /// deadlock, the new work first runs on a later tick and the count of registrations grows by exactly one.
    @Test func workMayRegisterMoreWorkInsideFire() {
        let tick = PollTick()
        let outer = Count(), inner = Count()
        let registered = Count()
        _ = tick.every(0.5) {
            outer.bump()
            if registered.value == 0 {
                registered.bump()
                _ = tick.every(0.5) { inner.bump() }
            }
        }

        fire(tick, 3)

        #expect(outer.value == 3)
        #expect(tick.registrationCount == 2)
        #expect(inner.value == 2, "new work joins from the tick after it registered")
    }

    /// OC-381-12. concurrent registration/cancellation while another thread fires: given 4 threads registering and
    /// cancelling 200 pieces of work each while a fifth fires 2000 ticks, then nothing crashes and every
    /// registration is gone at the end. Red on a data race that corrupts the table (count != 0 or a trap).
    @Test func registeringAndCancellingWhileFiringLeavesNothingBehind() async {
        let tick = PollTick()
        let keep = Count()
        _ = tick.every(0.5) { keep.bump() }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { for _ in 0..<2000 { tick.fire() } }
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<200 {
                        let cancel = tick.every(1) {}
                        cancel()
                    }
                }
            }
        }

        #expect(tick.registrationCount == 1, "only the control registration is left")
        #expect(keep.value == 2000)
    }

    /// OC-381-13. empty: given nothing registered, fire() is a no-op that does not crash, and work registered after
    /// 7 ticks have passed is on the SHARED count: every(5) first runs on global tick 10, 3 ticks later.
    /// (Documents the phase: a re-registration does not restart the period, it joins the global one.)
    @Test func ticksAreGlobalSoLateWorkJoinsTheSharedPhase() {
        let tick = PollTick()
        fire(tick, 7)
        #expect(tick.registrationCount == 0)
        let count = Count()
        _ = tick.every(5) { count.bump() }

        fire(tick, 2)
        #expect(count.value == 0)
        tick.fire()
        #expect(count.value == 1, "ran on global tick 10")
    }

    /// OC-381-14. the poll constants every period is a multiple of (FR-001-01), literal values.
    @Test func theTickIsHalfASecondWithTenthSecondTolerance() {
        #expect(PollTick.interval == 0.5)
        #expect(PollTick.tolerance == 0.1)
    }

    private final class CancelBox: @unchecked Sendable { var cancel: (@Sendable () -> Void)? }
}
