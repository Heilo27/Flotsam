import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

/// TASK-381: the capture timer is the one clock that drives `PollTick` (ADR-0004). These use the real timer, because
/// the claim under test is that the timer, not a test, fires the tick.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct Worf381PollTickTimerTests {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// OC-381-20. given capture mode Paused and a started capture, when 1.7 s of real time passes, then registered
    /// work ran 2-4 times (the tick keeps firing while Paused, ADR-0004 / FR-001-19) while no pasteboard bytes were
    /// read. Red if the timer is only scheduled for Active mode, or if fire() is placed after an early return of poll().
    @Test("OC-381-20 the tick keeps firing while capture is Paused")
    func tickFiresWhilePaused() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        let ran = Count()
        let cancel = tick.every(0.5) { ran.bump() }
        defer { cancel() }

        rig.capture.start()
        try await Task.sleep(for: .milliseconds(1700))
        let fired = ran.value
        rig.text("copied while paused")
        try await Task.sleep(for: .milliseconds(700))
        let firedAfterCopy = ran.value
        await rig.settle()

        #expect(fired >= 2 && fired <= 4, "ticks in 1.7 s: \(fired)")
        #expect(firedAfterCopy > fired, "still firing after a copy while Paused")
        #expect(await rig.itemCount() == 0, "Paused saved nothing")
    }

    /// OC-381-21. given a started capture, when start() is called a second time, then the tick rate does not double
    /// (a second timer would double the watchdog and re-resolve rate). 1.7 s of real time: at most 4 firings.
    @Test("OC-381-21 a second start() adds no second tick source")
    func secondStartDoesNotDoubleTheTick() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        let ran = Count()
        let cancel = tick.every(0.5) { ran.bump() }
        defer { cancel() }

        rig.capture.start()
        rig.capture.start()
        try await Task.sleep(for: .milliseconds(1700))
        let fired = ran.value
        await rig.settle()

        #expect(fired >= 2 && fired <= 4, "ticks in 1.7 s: \(fired)")
    }

    /// OC-381-22. given a stopped capture, then the tick stops firing, which is why AppContainer must never stop
    /// capture while the watchdog should run (it only stops triggers on quit). Pins the coupling: red if stop() leaves
    /// the timer running.
    @Test("OC-381-22 stop() ends the tick")
    func stopEndsTheTick() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        let ran = Count()
        let cancel = tick.every(0.5) { ran.bump() }
        defer { cancel() }

        rig.capture.start()
        try await Task.sleep(for: .milliseconds(1200))
        await rig.capture.stop()
        let atStop = ran.value
        try await Task.sleep(for: .milliseconds(1200))

        #expect(atStop >= 1, "control: it fired while running")
        #expect(ran.value == atStop)
    }
}
