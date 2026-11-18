import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

/// TASK-381: the capture timer is the one clock that drives `PollTick` (ADR-0004). OC-381-20 and -22 use the real timer, because
/// the claim under test is that the timer, not a test, fires the tick; OC-381-21 uses the timer seam (ADR-0011).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct Worf381PollTickTimerTests {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// OC-381-20. given capture mode Paused and a started capture, when 1.7 s of ticks pass (1.7 s at the scheduled
    /// interval is 3 fires), then registered work ran 3 times (2-4: the tick keeps firing while Paused, ADR-0004 /
    /// FR-001-19) while nothing was stored. Red if the timer is only scheduled for Active mode, or if fire() is placed
    /// after an early return of poll(). Runs on the timer seam (ADR-0011): the real-timer count of ticks in 1.7 s
    /// fell outside 2-4 when the main actor was starved under a full-suite run (TASK-447), so the source is fired by
    /// hand and its scheduled interval is what ties the fire count to the 1.7 s window.
    @Test("OC-381-20 the tick keeps firing while capture is Paused")
    func tickFiresWhilePaused() async throws {
        let tick = PollTick()
        let timers = FakeTimers()
        let rig = try await GapRig(pollTick: tick, scheduleTimer: timers.schedule)
        defer { Task { await rig.cleanUp() } }
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        let ran = Count()
        let cancel = tick.every(0.5) { ran.bump() }
        defer { cancel() }

        rig.capture.start()
        await Task.yield()
        await Task.yield()
        let source = try #require(timers.live.first, "a Paused capture still schedules its tick source")
        #expect(timers.live.count == 1, "sources live: \(timers.live.count)")
        let expectedFires = Int(1.7 / source.interval)
        #expect(expectedFires >= 2 && expectedFires <= 4, "fires in 1.7 s at interval \(source.interval): \(expectedFires)")

        for _ in 0..<expectedFires { source.fire() }
        let fired = ran.value
        rig.text("copied while paused")
        for _ in 0..<Int(0.7 / source.interval) + 1 { source.fire() }
        let firedAfterCopy = ran.value
        await rig.settle()

        #expect(fired >= 2 && fired <= 4, "ticks in 1.7 s: \(fired)")
        #expect(firedAfterCopy > fired, "still firing after a copy while Paused")
        #expect(await rig.itemCount() == 0, "Paused saved nothing")
    }

    /// OC-381-21. given a started capture, when start() is called a second time, then no second tick source is
    /// created (a second timer would double the watchdog and re-resolve rate). Runs on the timer seam (ADR-0011): the
    /// test counts the sources `ClipboardCapture` schedules and fires them by hand, so no real time passes. Red if a
    /// second start() schedules (or reschedules) a source: the created count and the live count both catch it.
    @Test("OC-381-21 a second start() adds no second tick source")
    func secondStartDoesNotDoubleTheTick() async throws {
        let tick = PollTick()
        let timers = FakeTimers()
        let rig = try await GapRig(pollTick: tick, scheduleTimer: timers.schedule)
        defer { Task { await rig.cleanUp() } }
        let ran = Count()
        let cancel = tick.every(0.5) { ran.bump() }
        defer { cancel() }

        rig.capture.start()
        rig.capture.start()
        // Let the cadence-observer hop (a main-actor Task) land, so a late reschedule would show up as a source.
        await Task.yield()
        await Task.yield()

        #expect(timers.created.count == 1, "sources created: \(timers.created.count)")
        #expect(timers.live.count == 1, "sources live: \(timers.live.count)")
        #expect(timers.created.first?.interval == PollTick.interval)
        #expect(timers.created.first?.tolerance == PollTick.tolerance)

        guard let source = timers.created.first else { return }
        #expect(ran.value == 0, "control: nothing ran before the source fired")
        source.fire()
        #expect(ran.value == 1, "one fire is one tick")
        source.fire()
        source.fire()
        #expect(ran.value == 3, "ticks after 3 fires: \(ran.value)")
    }

    /// OC-381-22. given a stopped capture, then the tick stops firing, which is why AppContainer must never stop
    /// capture while the watchdog should run (it only stops triggers on quit). Pins the coupling: red if stop() leaves
    /// the timer running. Runs on the timer seam (ADR-0011): the scheduled source is fired by hand while running, and
    /// after stop() it must be cancelled and a fire must not reach the tick (TASK-447: the real-timer version waited
    /// out wall-clock windows).
    @Test("OC-381-22 stop() ends the tick")
    func stopEndsTheTick() async throws {
        let tick = PollTick()
        let timers = FakeTimers()
        let rig = try await GapRig(pollTick: tick, scheduleTimer: timers.schedule)
        defer { Task { await rig.cleanUp() } }
        let ran = Count()
        let cancel = tick.every(0.5) { ran.bump() }
        defer { cancel() }

        rig.capture.start()
        await Task.yield()
        await Task.yield()
        let source = try #require(timers.live.first, "start() schedules the tick source")
        source.fire()
        source.fire()
        await rig.capture.stop()
        let atStop = ran.value

        #expect(atStop >= 1, "control: it fired while running")
        #expect(source.isCancelled && timers.live.isEmpty, "stop() left a tick source running")
        source.fire()
        source.fire()
        #expect(ran.value == atStop)
    }
}

/// The ADR-0011 timer seam as a test double: records every source `ClipboardCapture` schedules, and lets the test fire
/// a source by hand. Nothing here waits on a run loop.
@MainActor
final class FakeTimers {
    final class Source {
        let interval: TimeInterval
        let tolerance: TimeInterval
        fileprivate(set) var isCancelled = false
        private let body: @MainActor () -> Void
        init(interval: TimeInterval, tolerance: TimeInterval, body: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.tolerance = tolerance
            self.body = body
        }
        /// One firing of the source, as the run loop would deliver it. A cancelled source never fires.
        @MainActor func fire() { if !isCancelled { body() } }
    }

    private(set) var created: [Source] = []
    var live: [Source] { created.filter { !$0.isCancelled } }

    var schedule: ClipboardCapture.TimerScheduler {
        { [self] interval, tolerance, fire in
            let source = Source(interval: interval, tolerance: tolerance, body: fire)
            created.append(source)
            return { source.isCancelled = true }
        }
    }
}
