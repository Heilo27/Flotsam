import Foundation
import Testing
@testable import FlotsamBase

/// TASK-427 D3: `PollTick.every(_:)` converted `seconds / interval` with `Int(...)`, which traps on NaN, infinity and
/// any value past `Int.max`. A trap is a crash, so the check runs in a child process (`processExitsWith`).
@Suite("PollTick.every interval hardening", .serialized)
struct Task427PollTickEveryTests {
    @Test("OC-427-30 a non-finite or enormous interval does not trap")
    func hostileIntervalsDoNotTrap() async {
        await #expect(processExitsWith: .success) { _ = PollTick().every(.nan) {} }
        await #expect(processExitsWith: .success) { _ = PollTick().every(.infinity) {} }
        await #expect(processExitsWith: .success) { _ = PollTick().every(-.infinity) {} }
        await #expect(processExitsWith: .success) { _ = PollTick().every(.greatestFiniteMagnitude) {} }
        await #expect(processExitsWith: .success) { _ = PollTick().every(1e19) {} }
        await #expect(processExitsWith: .success) { _ = PollTick().every(-1e19) {} }
    }

    /// Clamped, not dropped: the registration exists and a Paused timer's cadence is bounded by `maxPeriod`.
    @Test("OC-427-31 an enormous interval is clamped to maxPeriod; NaN and non-positive run every tick")
    func clamping() {
        let huge = PollTick()
        huge.setFastTickNeeded(false)
        let cancelHuge = huge.every(.infinity) {}
        #expect(huge.registrationCount == 1)
        #expect(huge.cadence == PollTick.maxPeriod)
        cancelHuge()
        #expect(huge.registrationCount == 0)

        for seconds in [TimeInterval.nan, -TimeInterval.infinity, -5, 0] {
            let tick = PollTick()
            tick.setFastTickNeeded(false)
            let ran = LockedValue(0)
            _ = tick.every(seconds) { ran.withLock { $0 += 1 } }
            #expect(tick.cadence == PollTick.interval, "\(seconds) means every tick")
            tick.fire()
            #expect(ran.withLock { $0 } == 1)
        }
    }

    @Test("OC-427-32 a normal period is unchanged")
    func normalPeriodUnchanged() {
        let tick = PollTick()
        let ran = LockedValue(0)
        _ = tick.every(5) { ran.withLock { $0 += 1 } }
        for _ in 0..<19 { tick.fire() }
        #expect(ran.withLock { $0 } == 1, "5 s is the 10th tick")
    }
}
