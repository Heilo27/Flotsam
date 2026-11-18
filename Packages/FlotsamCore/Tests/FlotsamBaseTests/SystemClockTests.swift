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

    // OC-0077. Given a task already cancelled before the sleep starts. When sleep(for: 1 hour) is awaited.
    // Then it returns without throwing and Task.isCancelled is true.
    // Red if: cancellation no longer returns early (sleeps the full hour: the hang guard fires), or the flag is lost.
    // No elapsed-time bound (TASK-462: a 1 s bound failed at machine load 27-77; TASK-447's best-of-three did not
    // settle it). The sleep is an hour and the only clock is a 30 s hang guard, so the two outcomes are 120x apart:
    // a woken sleep returns in microseconds of work however starved the machine, a sleep that ignores cancellation
    // is still asleep when the guard fires. SystemClock is the one real sleeper, so there is no clock to inject.
    @Test("sleep in a task cancelled before it starts returns early and leaves the task cancelled")
    func cancelledBeforeSleepReturnsEarly() async {
        let task = Task {
            // Hold until the outer cancel() lands, so the sleep begins in an already-cancelled task.
            while !Task.isCancelled { await Task.yield() }
            return await timedSleep(.seconds(3600))
        }
        task.cancel()
        let outcome = await first(of: task)
        #expect(outcome != nil, "sleep did not return within the hang guard: cancellation does not wake it")
        #expect(outcome?.cancelledAfter == true)
    }

    // OC-0077. Given a task that has signalled it is about to sleep 1 hour. When it is cancelled after that signal.
    // Then sleep returns without throwing and Task.isCancelled is true.
    // Red if: cancellation during the sleep does not wake it (the hang guard fires), or the cancelled flag is lost.
    // No elapsed bound, as above. "Sleeps at all" is owned by the live 50 ms test above (red if sleep is skipped or
    // shortened): when the cancel lands relative to the sleep is scheduler-dependent, so this test asserts neither.
    @Test("cancelling during a 1 hour sleep wakes it early")
    func cancelledDuringSleepReturnsEarly() async {
        let (signals, signal) = AsyncStream<Void>.makeStream()
        let task = Task { await timedSleep(.seconds(3600), onAboutToSleep: { signal.yield() }) }
        for await _ in signals { break }  // deterministic: cancel only after the task reached its sleep
        task.cancel()
        let outcome = await first(of: task)
        #expect(outcome != nil, "sleep did not return within the hang guard: cancellation does not wake it")
        #expect(outcome?.cancelledAfter == true)
    }
}

/// The task's outcome, or nil when it has not finished within `hangGuard` (a hang guard, never a delay: it returns the
/// moment the task finishes). Unstructured on purpose: a task group would wait for the still-sleeping task on exit.
private func first(of task: Task<SleepOutcome, Never>, hangGuard: Duration = .seconds(30)) async -> SleepOutcome? {
    let (results, deliver) = AsyncStream<SleepOutcome?>.makeStream()
    Task { deliver.yield(await task.value) }
    let timeout = Task {
        try? await Task.sleep(for: hangGuard)
        if !Task.isCancelled { deliver.yield(nil) }
    }
    var outcome: SleepOutcome?
    for await result in results { outcome = result; break }
    timeout.cancel()
    return outcome
}
