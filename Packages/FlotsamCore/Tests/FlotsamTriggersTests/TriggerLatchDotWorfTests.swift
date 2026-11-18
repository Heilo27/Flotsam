import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// Independent checks for TASK-399 (FR-005-19 / AC-005-18): the warning dot follows the latch, not the status.
/// Fake tap only. Each test names the production change that turns it red.
@MainActor
@Suite struct TriggerLatchDotWorfTests {
    private let itemId = ExpanderHarness.itemId

    private func latched() async -> EngineHarness {
        let h = EngineHarness(triggers: [itemId: ";zqxsig"])
        await h.engine.start()
        for _ in 0..<3 { h.source.simulateDisable() }
        #expect(await eventually { h.engine.status == .latchedOff })
        return h
    }

    // OC-5126-adjacent. Red if showsWarningDot reverts to `status == .latchedOff` (dot drops when the last trigger
    // goes: status .idle, latch still held).
    @Test func theDotHoldsWhenTheLastTriggerIsRemovedWhileLatched() async {
        // given: latched, dot set
        let h = await latched()
        defer { h.engine.stop() }
        #expect(h.engine.showsWarningDot)

        // when: the only trigger is removed and the engine reconciles
        h.bindings.setTriggers([:])
        h.bus.publish(.itemsChanged)

        // then: status is .idle but the dot is still set
        #expect(await eventually { h.engine.status == .idle })
        #expect(h.engine.showsWarningDot)
    }

    // Red if a re-grant reinstalled the tap or cleared the latch: after re-grant the engine must be latchedOff
    // again (not running), the dot set, and the tap not re-installed (startCount unchanged).
    @Test func afterReGrantTheLatchAndDotAreStillSetAndNoTapIsReinstalled() async {
        let h = await latched()
        defer { h.engine.stop() }
        let starts = h.source.startCount

        h.base.permissions.set(.inputMonitoring, granted: false)
        await h.engine.watchdogTick()
        #expect(h.engine.showsWarningDot)
        h.base.permissions.set(.inputMonitoring, granted: true)
        await h.engine.watchdogTick()

        #expect(h.engine.status == .latchedOff)
        #expect(h.engine.showsWarningDot)
        #expect(h.source.startCount == starts)
    }

    // AC-005-18: toggle off while a permission is missing still clears the latch and the dot; toggling on with the
    // permission back restores the tap. Red if the reset were moved behind the permission check.
    @Test func toggleOffWhilePermissionRevokedClearsTheLatchAndDot() async {
        let h = await latched()
        defer { h.engine.stop() }
        h.base.permissions.set(.inputMonitoring, granted: false)
        await h.engine.watchdogTick()
        #expect(h.engine.showsWarningDot)

        h.settings.set(false, for: SettingKeys.triggersEnabled)
        #expect(await eventually { h.engine.status == .off })
        #expect(!h.engine.showsWarningDot)

        h.base.permissions.set(.inputMonitoring, granted: true)
        h.settings.set(true, for: SettingKeys.triggersEnabled)
        #expect(await eventually { h.engine.status == .running })
        #expect(!h.engine.showsWarningDot)
    }

    // Negative: a never-latched engine with a revoked permission shows no dot (red if the dot became `!= .running`).
    @Test func aRevokedPermissionWithoutALatchShowsNoDot() async {
        let h = EngineHarness(triggers: [itemId: ";zqxsig"])
        await h.engine.start()
        defer { h.engine.stop() }
        h.base.permissions.set(.inputMonitoring, granted: false)
        await h.engine.watchdogTick()

        guard case .inert = h.engine.status else { Issue.record("expected .inert, got \(h.engine.status)"); return }
        #expect(!h.engine.showsWarningDot)
    }
}
