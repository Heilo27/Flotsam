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

private func timedSleep(_ duration: Duration, onAboutToSleep: (@Sendable () -> Void)? = nil) async -> SleepOutcome {
    let clock = ContinuousClock()
    let start = clock.now
    onAboutToSleep?()
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
    // Wall-clock bound with no clock seam (SystemClock is the one real sleeper): the metric is the best of up to three
    // runs against the unchanged 1 s bound, so a starved run passes on a retry while a sleep that ignores
    // cancellation takes 10 s on every run (TASK-447).
    @Test("sleep in a task cancelled before it starts returns early and leaves the task cancelled")
    func cancelledBeforeSleepReturnsEarly() async {
        var best = Duration.seconds(1_000)
        for _ in 1...3 {
            let task = Task {
                // Hold until the outer cancel() lands, so the sleep begins in an already-cancelled task.
                while !Task.isCancelled { await Task.yield() }
                return await timedSleep(.seconds(10))
            }
            task.cancel()
            let outcome = await task.value
            #expect(outcome.cancelledAfter == true)
            best = min(best, outcome.elapsed)
            if best < .seconds(1) { break }
        }
        #expect(best < .seconds(1))
    }

    // OC-0077. Given a task that has signalled it is about to sleep 10 s. When it is cancelled after that signal.
    // Then sleep returns in under 1 s total, without throwing, and Task.isCancelled is true.
    // Red if: cancellation during the sleep does not wake it (sleeps the full 10 s), or the cancelled flag is lost.
    // No lower bound on elapsed: when the cancel lands relative to the sleep is scheduler-dependent, so any floor
    // flaked under load (the child could start after cancel(), elapsed ~0). "Sleeps at all" is owned by the live
    // 50 ms test above (red if sleep is skipped or shortened). Best of up to three runs for the 1 s bound, as above.
    @Test("cancelling during a 10 s sleep wakes it early")
    func cancelledDuringSleepReturnsEarly() async {
        var best = Duration.seconds(1_000)
        for _ in 1...3 {
            let (signals, signal) = AsyncStream<Void>.makeStream()
            let task = Task { await timedSleep(.seconds(10), onAboutToSleep: { signal.yield() }) }
            for await _ in signals { break }  // deterministic: cancel only after the task reached its sleep
            task.cancel()
            let outcome = await task.value
            #expect(outcome.cancelledAfter == true)
            best = min(best, outcome.elapsed)
            if best < .seconds(1) { break }
        }
        #expect(best < .seconds(1))
    }
}
