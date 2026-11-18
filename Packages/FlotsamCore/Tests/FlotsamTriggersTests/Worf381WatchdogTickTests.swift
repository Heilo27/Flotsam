import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// TASK-381: the watchdog is a registration on `PollTick`, not a loop. Fake tap only.
@MainActor
@Suite struct Worf381WatchdogTickTests {
    private let itemId = ExpanderHarness.itemId

    /// OC-381-30. given a started engine, when 9 ticks fire, then no watchdog pass has run (a permission revoked
    /// meanwhile is still unseen); the 10th tick runs one. Red if the divisor is 5 or 20, or the watchdog runs per tick.
    @Test func theWatchdogRunsOnTheTenthTickNotBefore() async {
        let h = EngineHarness(triggers: [itemId: ";zqxsig"])
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.engine.status == .running)
        h.base.permissions.set(.inputMonitoring, granted: false)

        for _ in 0..<9 { h.pollTick.fire() }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.engine.status == .running, "9 ticks: no watchdog pass yet")

        h.pollTick.fire()
        #expect(await eventually { h.engine.status == .inert([.setPrm002]) })
    }

    /// OC-381-31. given a stopped engine, then its registration is cancelled (registrationCount 1 -> 0) and later
    /// ticks do not reinstall the tap. Red if stop() forgets cancelWatchdog.
    @Test func stopCancelsTheWatchdogRegistration() async {
        let h = EngineHarness(triggers: [itemId: ";zqxsig"])
        await h.engine.start()
        #expect(h.pollTick.registrationCount == 1)

        h.engine.stop()
        #expect(h.pollTick.registrationCount == 0)
        let installs = h.source.startCount
        h.runWatchdogPass()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(h.source.startCount == installs)
        #expect(!h.source.isInstalled)
    }

    /// OC-381-32. race: given a watchdog pass spawned by the 10th tick and stop() called before that pass runs, then
    /// the tap must stay uninstalled. (The pass is a `Task` that outlives `cancelWatchdog`; if it runs after stop() its
    /// reconcile installs a tap on a stopped engine.)
    @Test("KNOWN TASK-381 defect D1: a watchdog pass spawned before stop() reinstalls the tap")
    func aPassSpawnedBeforeStopDoesNotReinstallTheTap() async {
        let h = EngineHarness(triggers: [itemId: ";zqxsig"])
        await h.engine.start()
        #expect(h.source.isInstalled)

        h.runWatchdogPass()  // spawns the pass; main actor has not run it yet
        h.engine.stop()
        try? await Task.sleep(for: .milliseconds(200))

        // Remove `withKnownIssue` when TriggerEngine.stop() makes a pass spawned before it a no-op.
        withKnownIssue("D1: the pass is a Task that outlives cancelWatchdog; its reconcile reinstalls the tap") {
            #expect(!h.source.isInstalled, "a stopped engine must not hold a tap")
        }
    }

    /// OC-381-33. FR-005-19 resume path: given a tap found disabled, when the system resumes, then the tap is
    /// re-enabled at once with no tick fired (resume does not wait for the 5 s tick).
    @Test func systemDidResumeReenablesWithoutWaitingForATick() async {
        let h = EngineHarness(triggers: [itemId: ";zqxsig"])
        await h.engine.start()
        defer { h.engine.stop() }
        h.source.disableSilently()
        let before = h.source.reenableCount

        await h.engine.systemDidResume()

        #expect(h.source.reenableCount == before + 1)
        #expect(h.source.isHealthy)
    }
}
