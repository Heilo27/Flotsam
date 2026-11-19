import Foundation
import Testing
@testable import FlotsamBase

// TASK-521 Worf findings 1 and 2 (OC-8024 / FR-008-03). A user's explicit open outranks a passive launch show: a
// non-forcing call never cancels a pending forced follow-up, a forcing call still replaces one, and the setup guide's
// already-open path honours `resuming` the same way its fresh-window path does.

/// A clock whose `sleep` parks until released and, like `SystemClock`, returns early when its task is cancelled.
@MainActor
private final class GateClock: WallClock {
    nonisolated func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    final class Sleeper: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
    }
    private var sleepers: [Sleeper] = []
    var parked: Int { sleepers.count }

    nonisolated func sleep(for duration: Duration) async {
        let sleeper = Sleeper()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Task { @MainActor in
                    sleeper.continuation = continuation
                    self.sleepers.append(sleeper)
                }
            }
        } onCancel: {
            Task { @MainActor in
                sleeper.continuation?.resume()
                sleeper.continuation = nil
            }
        }
    }

    func releaseAll() {
        for sleeper in sleepers {
            sleeper.continuation?.resume()
            sleeper.continuation = nil
        }
    }
}

@MainActor
private final class LogWindow: FrontableWindow {
    var log: [String] = []
    var appIsActive: Bool { false }
    var windowIsOpen: Bool { true }
    func requestAppActivation() { log.append("request") }
    func orderFrontAndMakeKey() { log.append("front") }
    func forceAppActivation() { log.append("force") }
    var forces: Int { log.filter { $0 == "force" }.count }
}

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<2_000 where !condition() { await Task.yield() }
}

@MainActor
@Suite("TASK-521 follow-up precedence: the user's open outranks a passive show") struct Task521FollowUpPrecedenceTests {
    // Red if `followUp?.cancel()` runs before `guard forcing` again (the passive show cancels the user's follow-up).
    @Test("a non-forcing show inside the grace does not cancel the user's pending forced follow-up")
    func passiveShowKeepsUsersFollowUp() async {
        let clock = GateClock(), window = LogWindow()
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)  // the user's open
        await settle { clock.parked == 1 }
        fronting.bringToFront(window, forcing: false)  // a passive show inside the grace
        #expect(window.log == ["request", "front", "request", "front"], "the passive show still asks and shows")
        clock.releaseAll()
        await settle { window.forces == 1 }
        for _ in 0..<50 { await Task.yield() }
        #expect(window.forces == 1, "the user's follow-up still forces")
    }

    // Red if a forcing call stops cancelling the earlier follow-up (two forces for two opens).
    @Test("a forcing show replaces a pending follow-up: two user opens in the grace force once")
    func forcingShowReplacesFollowUp() async {
        let clock = GateClock(), window = LogWindow()
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)
        await settle { clock.parked == 1 }
        fronting.bringToFront(window)
        await settle { clock.parked == 2 }
        clock.releaseAll()
        await settle { window.forces >= 1 }
        for _ in 0..<50 { await Task.yield() }
        #expect(window.forces == 1)
    }

    // The setup guide's controller is App code the package cannot instantiate; pin its two fronting calls by source.
    // Red if the already-open path goes back to `front?.bringToFront()` (a launch-time re-show would then force).
    @Test("the setup guide's already-open path passes the same forcing rule as its fresh-window path")
    func onboardingExistingWindowHonoursResuming() throws {
        let code = try frd008Code("App/Flotsam/OnboardingWindowController.swift")
        #expect(code.contains("front?.bringToFront(forcing: !resuming)"))
        #expect(code.contains("front.bringToFront(forcing: !resuming)"))
        #expect(!code.contains("front?.bringToFront()"))
    }
}
