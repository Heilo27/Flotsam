import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

/// TASK-430 edge cases on the ADR-0011 timer seam (`ClipboardCapture.TimerScheduler`). Every expected value is a literal.
/// The double here does NOT guard `fire()` on cancellation (unlike `FakeTimers`), so a body that still runs after cancel
/// is visible: it models a firing already queued when the source was cancelled.
@MainActor
final class RawTimers {
    @MainActor final class Source {
        let interval: TimeInterval
        let tolerance: TimeInterval
        var cancelCalls = 0
        private let body: @MainActor () -> Void
        init(interval: TimeInterval, tolerance: TimeInterval, body: @escaping @MainActor () -> Void) {
            self.interval = interval; self.tolerance = tolerance; self.body = body
        }
        var isCancelled: Bool { cancelCalls > 0 }
        /// Delivers one firing whether or not the source was cancelled.
        func rawFire() { body() }
    }
    private(set) var created: [Source] = []
    var live: [Source] { created.filter { !$0.isCancelled } }
    var schedule: ClipboardCapture.TimerScheduler {
        { [self] interval, tolerance, fire in
            let source = Source(interval: interval, tolerance: tolerance, body: fire)
            created.append(source)
            return { source.cancelCalls += 1 }
        }
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct Worf430TimerSeamTests {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func settleHops() async { for _ in 0..<4 { await Task.yield() } }

    /// OC-430-01. given a started capture with one source, when stop() runs, then that source is cancelled exactly once,
    /// no source is live and none was added. Red if stop() leaves the source un-cancelled or cancels it twice.
    @Test("OC-430-01 stop() cancels the one source exactly once")
    func stopCancelsTheSource() async throws {
        let timers = RawTimers()
        let rig = try await GapRig(scheduleTimer: timers.schedule)
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        await settleHops()
        #expect(timers.created.count == 1 && timers.live.count == 1, "control: one live source while started")
        #expect(rig.capture.scheduledTimerInterval == 0.5)

        await rig.capture.stop()
        await settleHops()

        #expect(timers.created.count == 1, "created: \(timers.created.count)")
        #expect(timers.live.count == 0, "live after stop: \(timers.live.count)")
        #expect(timers.created.first?.cancelCalls == 1, "cancel calls: \(String(describing: timers.created.first?.cancelCalls))")
        #expect(rig.capture.scheduledTimerInterval == nil)
    }

    /// OC-430-02. given start, stop, start, then exactly one NEW source exists (two created in total), the first stays
    /// cancelled and the second is live at 0.5 s / 0.1 s tolerance. Red if stop() leaves state that makes the second
    /// start reuse the dead source (created stays 1), or if the second start double-schedules (created 3).
    @Test("OC-430-02 start, stop, start creates exactly one fresh source")
    func restartCreatesOneFreshSource() async throws {
        let timers = RawTimers()
        let rig = try await GapRig(scheduleTimer: timers.schedule)
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        await rig.capture.stop()
        rig.capture.start()
        await settleHops()

        #expect(timers.created.count == 2, "created: \(timers.created.count)")
        #expect(timers.live.count == 1, "live: \(timers.live.count)")
        #expect(timers.created.first?.cancelCalls == 1)
        #expect(timers.created.last?.isCancelled == false)
        #expect(timers.created.last?.interval == 0.5)
        #expect(timers.created.last?.tolerance == 0.1)
    }

    /// OC-430-03. given a started capture with a 5 s job registered, when capture is Paused, then the 0.5 s source is
    /// cancelled once and exactly one 5 s source is created; when resumed, the 5 s source is cancelled and one new 0.5 s
    /// source is created. Red if a cadence change leaves the old source live (two live), skips the reschedule, or
    /// reschedules at the wrong interval.
    @Test("OC-430-03 a cadence change cancels the old source and creates one new one")
    func cadenceChangeReschedules() async throws {
        let tick = PollTick()
        let timers = RawTimers()
        let rig = try await GapRig(pollTick: tick, scheduleTimer: timers.schedule)
        defer { Task { await rig.cleanUp() } }
        let cancelJob = tick.every(5) {}
        defer { cancelJob() }
        rig.capture.start()
        await settleHops()
        #expect(timers.created.map(\.interval) == [0.5], "control: starts at 0.5 s")

        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        await settleHops()
        #expect(timers.created.map(\.interval) == [0.5, 5.0], "after pause: \(timers.created.map(\.interval))")
        #expect(timers.live.map(\.interval) == [5.0], "live after pause: \(timers.live.map(\.interval))")
        #expect(timers.created[0].cancelCalls == 1)

        rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
        await settleHops()
        #expect(timers.created.map(\.interval) == [0.5, 5.0, 0.5], "after resume: \(timers.created.map(\.interval))")
        #expect(timers.live.map(\.interval) == [0.5], "live after resume: \(timers.live.map(\.interval))")
        #expect(timers.created[1].cancelCalls == 1)
    }

    /// OC-430-04. given a started capture with no registered work, when capture is Paused, then the only source is
    /// cancelled and none is created (nothing needs a firing); resuming creates exactly one. Red if pause keeps the
    /// source or schedules a nil-cadence source.
    @Test("OC-430-04 pausing with no work cancels the source and schedules none")
    func pauseWithNoWorkLeavesNoSource() async throws {
        let timers = RawTimers()
        let rig = try await GapRig(scheduleTimer: timers.schedule)
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        await settleHops()

        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        await settleHops()
        #expect(timers.created.count == 1 && timers.live.count == 0, "created \(timers.created.count) live \(timers.live.count)")
        #expect(rig.capture.scheduledTimerInterval == nil)

        rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
        await settleHops()
        #expect(timers.created.count == 2 && timers.live.count == 1, "after resume created \(timers.created.count) live \(timers.live.count)")
    }

    /// OC-430-05. given a registered tick job and a stopped capture, when a firing already queued on the cancelled
    /// source is delivered, then the job does not run (count stays 0, after a control fire that ran it once while
    /// started). Red if timerFired() does work once the capture is stopped.
    @Test("OC-430-05 a fire delivered after stop() does no work")
    func fireAfterCancelDoesNoWork() async throws {
        let tick = PollTick()
        let timers = RawTimers()
        let rig = try await GapRig(pollTick: tick, scheduleTimer: timers.schedule)
        defer { Task { await rig.cleanUp() } }
        let ran = Count()
        let cancelJob = tick.every(0.5) { ran.bump() }
        defer { cancelJob() }
        rig.capture.start()
        await settleHops()
        guard let source = timers.created.first else { Issue.record("no source created"); return }
        source.rawFire()
        #expect(ran.value == 1, "control: a fire while started ran the job once")

        await rig.capture.stop()
        // then: a firing delivered after stop() runs no job
        source.rawFire()
        source.rawFire()
        #expect(ran.value == 1, "jobs run after stop: \(ran.value - 1)")
    }
}
