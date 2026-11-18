import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// TASK-455: a trigger Notice raised for a condition that has since ended (a permission granted, a tap install that now
/// succeeds) must clear, or the menu-bar warning dot keeps saying "Needs attention" while the app works (FR-005-10,
/// FR-008-16, FR-000-08). Driven through `TriggerEngine` with a fake tap and a fake permission probe.
@MainActor
@Suite struct Task455NoticeRecoveryTests {
    private let itemId = ExpanderHarness.itemId

    private func harness() -> EngineHarness {
        EngineHarness(triggers: [itemId: ";zqxsig"], triggersEnabled: true, base: ExpanderHarness())
    }

    @Test func grantingInputMonitoringClearsTheSetPrm002Notice() async {
        let h = harness()
        h.base.permissions.set(.inputMonitoring, granted: false)
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.noticeCodes == [.setPrm002])

        h.base.permissions.set(.inputMonitoring, granted: true)
        h.runWatchdogPass()

        #expect(await eventually { h.engine.status == .running })
        #expect(await eventually { h.noticeCodes.isEmpty })
    }

    @Test func grantingAccessibilityClearsTheSetPrm001Notice() async {
        let h = harness()
        h.base.permissions.set(.accessibility, granted: false)
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.noticeCodes == [.setPrm001])

        h.base.permissions.set(.accessibility, granted: true)
        h.runWatchdogPass()

        #expect(await eventually { h.engine.status == .running })
        #expect(await eventually { h.noticeCodes.isEmpty })
    }

    @Test func aPermissionStillMissingKeepsItsNoticeWhileTheGrantedOneClears() async {
        let h = harness()
        h.base.permissions.set(.accessibility, granted: false)
        h.base.permissions.set(.inputMonitoring, granted: false)
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(Set(h.noticeCodes) == [.setPrm001, .setPrm002])

        h.base.permissions.set(.accessibility, granted: true)
        h.runWatchdogPass()

        #expect(await eventually { h.noticeCodes == [.setPrm002] })
        #expect(h.engine.status == .inert([.setPrm002]))
    }

    @Test func aTapInstallThatNowSucceedsClearsItsNotice() async {
        let h = harness()
        h.source.startFailure = FlotsamError(.trgOs001, "tap refused")
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.noticeCodes == [.trgOs001])

        h.source.startFailure = nil
        h.runWatchdogPass()

        #expect(await eventually { h.engine.status == .running })
        #expect(await eventually { h.noticeCodes.isEmpty })
    }
}
