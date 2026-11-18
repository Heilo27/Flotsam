import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

/// TASK-382 (FR-001-19, ADR-0004): while capture is Paused the 0.5 s poll does not run and the one timer slows to the
/// cadence `PollTick` gives the remaining work; resume brings 0.5 s back and re-baselines `changeCount`. These drive
/// `applyMode()` and `timerFired()` directly (the seams the timer and the settings subscription call), so nothing waits
/// on a real tick.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct Task382PausedPollTests {
    private final class Clock: @unchecked Sendable { var now = 0.0 }
    private final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        func record(_ time: Double) { lock.lock(); times.append(time); lock.unlock() }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return times }
    }

    private func pause(_ rig: GapRig) {
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        rig.capture.applyMode()
    }

    private func resume(_ rig: GapRig) {
        rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
        rig.capture.applyMode()
    }

    /// given a started Active capture with the watchdog and the re-resolve registered, when it is paused and resumed,
    /// then the shared timer is 0.5 s, then 5 s, then 0.5 s again, and there is only ever the one timer.
    @Test("the cadence changes on pause and on resume")
    func cadenceFollowsPauseAndResume() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        _ = tick.every(5) {}
        _ = tick.every(30) {}
        rig.capture.start()
        #expect(tick.cadence == 0.5)
        #expect(rig.capture.scheduledTimerInterval == 0.5)

        pause(rig)
        #expect(tick.cadence == 5)
        #expect(rig.capture.scheduledTimerInterval == 5)

        resume(rig)
        #expect(tick.cadence == 0.5)
        #expect(rig.capture.scheduledTimerInterval == 0.5)
    }

    @Test("starting while Paused schedules the slow timer, and with no other work no timer at all")
    func startingPaused() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        _ = tick.every(30) {}
        rig.capture.start()
        #expect(rig.capture.scheduledTimerInterval == 30)

        // The 5 s work joining while Paused speeds the one timer up to 5 s (the observer hops to the main actor).
        _ = tick.every(5) {}
        let sped = await eventually { rig.capture.scheduledTimerInterval == 5 }
        #expect(sped, "timer interval: \(String(describing: rig.capture.scheduledTimerInterval))")
    }

    @Test("Paused with nothing else registered leaves no timer scheduled")
    func pausedWithNoConsumersSchedulesNothing() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        #expect(rig.capture.scheduledTimerInterval == 0.5)
        pause(rig)
        #expect(tick.cadence == nil)
        #expect(rig.capture.scheduledTimerInterval == nil)
        resume(rig)
        #expect(rig.capture.scheduledTimerInterval == 0.5)
    }

    /// given Paused, when the timer fires many times, then the pasteboard is never read (no 0.5 s work runs).
    @Test("a timer firing while Paused does not touch the pasteboard")
    func pausedFiringReadsNothing() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        pause(rig)
        let reads = rig.pasteboard.changeCountReads
        for _ in 0..<20 { rig.capture.timerFired() }
        #expect(rig.pasteboard.changeCountReads == reads)
    }

    /// given Paused with the watchdog (5 s) and the re-resolve (30 s) registered, when the timer fires at the cadence
    /// the tick reports, then both run within their bounds, through a pause that starts mid-period and a resume.
    @Test("the watchdog and the re-resolve keep their bounds while Paused")
    func boundsHoldWhilePaused() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        let clock = Clock()
        let watchdog = Runs(), resolve = Runs()
        _ = tick.every(5) { watchdog.record(clock.now) }
        _ = tick.every(30) { resolve.record(clock.now) }
        rig.capture.start()

        func run(until end: Double) {
            while clock.now < end - 0.0001, let cadence = tick.cadence {
                clock.now += cadence
                rig.capture.timerFired()
            }
        }
        run(until: 6.5)
        pause(rig)
        let pausedAt = clock.now
        run(until: pausedAt + 120)
        #expect(tick.cadence == 5)
        resume(rig)
        run(until: clock.now + 20)

        func longestGap(_ runs: [Double]) -> Double {
            zip([0.0] + runs, runs + [clock.now]).map { $1 - $0 }.max() ?? clock.now
        }
        #expect(longestGap(watchdog.all) <= 5.0001, "watchdog: \(watchdog.all)")
        #expect(longestGap(resolve.all) <= 30.0001, "re-resolve: \(resolve.all)")
        let pausedWatchdogRuns = watchdog.all.filter { $0 > pausedAt && $0 <= pausedAt + 120 }.count
        #expect(pausedWatchdogRuns >= 23, "watchdog runs during the pause: \(pausedWatchdogRuns)")
    }

    /// given a copy made while Paused, when capture resumes, then it is never captured: not by the immediate check,
    /// not by later ticks. A copy made after the resume is captured (control).
    @Test("a copy made while Paused is never captured after resume")
    func copyWhilePausedIsNeverCaptured() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        pause(rig)
        rig.text("copied while paused")
        for _ in 0..<3 { rig.capture.timerFired() }

        resume(rig)
        for _ in 0..<3 { rig.capture.timerFired() }
        await rig.capture.stop()
        #expect(await rig.itemCount() == 0, "nothing copied while paused is captured")
    }

    @Test("a copy made after resume is captured")
    func copyAfterResumeIsCaptured() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        pause(rig)
        rig.text("copied while paused")
        resume(rig)
        rig.text("copied after resume")
        rig.capture.timerFired()

        let captured = await eventually { await rig.itemCount() == 1 }
        #expect(captured)
        await rig.capture.stop()
        let rows = try await rig.freshRows()
        #expect(rows.map(\.plainText) == ["copied after resume"])
    }
}
