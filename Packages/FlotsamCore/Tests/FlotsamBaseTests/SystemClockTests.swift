import Foundation
import Testing
@testable import FlotsamBase

// FRD-000 FR-000-01 (ruling 2026-11-16 b: non-throwing clock port), OC-0077. SystemClock is the one real sleeper;
// the paste 40 ms delay (ADR-0004) depends on it. Observed through real elapsed time on ContinuousClock and the
// task's own cancellation flag; expected values are literals.

private struct SleepOutcome: Sendable {
    let elapsed: Duration
    let cancelledAfter: Bool
}

private func timedSleep(_ duration: Duration) async -> SleepOutcome {
    let clock = ContinuousClock()
    let start = clock.now
    await SystemClock().sleep(for: duration)
    return SleepOutcome(elapsed: start.duration(to: clock.now), cancelledAfter: Task.isCancelled)
}

@Suite("SystemClock runtime (OC-0077)")
struct SystemClockTests {
    // OC-0077. Given the production clock in a live task. When sleep(for: 50 ms) is awaited.
    // Then at least 50 ms of real time passes and the task is not marked cancelled.
    // Red if: the sleep is skipped, shortened to .zero, or the body is empty.
    @Test("live 50 ms sleep takes at least 50 ms")
    func liveSleepTakesAtLeastTheDuration() async {
        let outcome = await Task { await timedSleep(.milliseconds(50)) }.value
        #expect(outcome.elapsed >= .milliseconds(50))
        #expect(outcome.elapsed < .seconds(5))
        #expect(outcome.cancelledAfter == false)
    }

    // OC-0077. Given a task already cancelled before the sleep starts. When sleep(for: 10 s) is awaited.
    // Then it returns without throwing in under 1 s and Task.isCancelled is true.
    // Red if: cancellation no longer returns early (sleeps the full duration), or the flag is lost.
    @Test("sleep in a task cancelled before it starts returns early and leaves the task cancelled")
    func cancelledBeforeSleepReturnsEarly() async {
        let task = Task {
            // Hold until the outer cancel() lands, so the sleep begins in an already-cancelled task.
            while !Task.isCancelled { await Task.yield() }
            return await timedSleep(.seconds(10))
        }
        task.cancel()
        let outcome = await task.value
        #expect(outcome.elapsed < .seconds(1))
        #expect(outcome.cancelledAfter == true)
    }

    // OC-0077. Given a task sleeping 10 s. When it is cancelled about 50 ms in.
    // Then sleep returns in under 1 s total, at least ~50 ms after it began, and Task.isCancelled is true.
    // Red if: cancellation during the sleep does not wake it, or sleep returns without sleeping at all.
    @Test("cancelling during a 10 s sleep wakes it early")
    func cancelledDuringSleepReturnsEarly() async throws {
        let task = Task { await timedSleep(.seconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.value
        #expect(outcome.elapsed < .seconds(1))
        #expect(outcome.elapsed >= .milliseconds(25))
        #expect(outcome.cancelledAfter == true)
    }
}
