import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// FR-005-10 (when a tap exists), FR-005-19 (tap health) and FR-005-22 (a deleted item stops expanding), driven through
/// `TriggerEngine` with a fake tap. Nothing here installs a real event tap or posts a keystroke.
@MainActor
@Suite struct TriggerEngineTests {
    private static let trigger = ";zqxsig"
    private let itemId = ExpanderHarness.itemId

    private func harness(
        triggers: [UUID: String]? = nil, triggersEnabled: Bool = true, base: ExpanderHarness = ExpanderHarness()
    ) -> EngineHarness {
        EngineHarness(triggers: triggers ?? [itemId: Self.trigger], triggersEnabled: triggersEnabled, base: base)
    }

    // MARK: AC-005-09 (FR-005-10)

    @Test func withNoTriggerThereIsNoTapAndNoPermissionPrompt() async {
        let h = harness(triggers: [:])
        h.base.permissions.set(.inputMonitoring, granted: false)
        h.base.permissions.set(.accessibility, granted: false)

        await h.engine.start()
        defer { h.engine.stop() }

        #expect(h.engine.status == .idle)
        #expect(h.source.startCount == 0)
        #expect(h.base.permissions.requested.isEmpty)
        #expect(await h.base.reportedCodes().isEmpty)
    }

    @Test func aTriggerWithInputMonitoringOffInstallsNoTapAndReportsSetPrm002() async {
        let h = harness()
        h.base.permissions.set(.inputMonitoring, granted: false)

        await h.engine.start()
        defer { h.engine.stop() }

        #expect(h.engine.status == .inert([.setPrm002]))
        #expect(h.source.startCount == 0)
        #expect(await h.base.reportedCodes() == [.setPrm002])
        #expect(h.noticeCodes == [.setPrm002])
        // Launch never prompts: only saving a trigger or turning triggers on does (FR-005-10).
        #expect(h.base.permissions.requested.isEmpty)
    }

    @Test func aSteadyMissingPermissionIsReportedOnceNotEveryWatchdogPass() async {
        let h = harness()
        h.base.permissions.set(.inputMonitoring, granted: false)
        await h.engine.start()
        defer { h.engine.stop() }

        await h.engine.watchdogTick()
        await h.engine.watchdogTick()

        #expect(await h.base.reportedCodes() == [.setPrm002])
    }

    @Test func grantingInputMonitoringInstallsTheTapOnTheNextWatchdogPass() async {
        let h = harness()
        h.base.permissions.set(.inputMonitoring, granted: false)
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.source.startCount == 0)

        h.base.permissions.set(.inputMonitoring, granted: true)
        h.runWatchdogPass()

        #expect(await eventually { h.engine.status == .running })
        #expect(h.source.startCount == 1)
        #expect(h.source.isInstalled)
    }

    @Test func accessibilityMissingAloneAlsoKeepsTheTapOff() async {
        let h = harness()
        h.base.permissions.set(.accessibility, granted: false)
        await h.engine.start()
        defer { h.engine.stop() }

        #expect(h.engine.status == .inert([.setPrm001]))
        #expect(h.source.startCount == 0)
    }

    @Test func revokingAPermissionWhileRunningRemovesTheTapOnTheNextPass() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.engine.status == .running)

        h.base.permissions.set(.inputMonitoring, granted: false)
        h.runWatchdogPass()

        #expect(await eventually { h.engine.status == .inert([.setPrm002]) })
        #expect(!h.source.isInstalled)
    }

    @Test func savingATriggerIsWhenMissingPermissionsArePrompted() async {
        let h = harness(triggers: [:])
        h.base.permissions.set(.inputMonitoring, granted: false)
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.base.permissions.requested.isEmpty)

        h.bindings.setTriggers([itemId: Self.trigger])
        await h.engine.userDidSaveTrigger()

        #expect(h.base.permissions.requested == [.inputMonitoring])
        #expect(h.engine.status == .inert([.setPrm002]))
    }

    @Test func triggersTurnedOffInstallNoTapEvenWithTriggersAndPermissions() async {
        let h = harness(triggersEnabled: false)
        await h.engine.start()
        defer { h.engine.stop() }

        #expect(h.engine.status == .off)
        #expect(h.source.startCount == 0)
    }

    @Test func aTapThatCannotBeInstalledIsReportedAndRetriedByTheWatchdog() async {
        let h = harness()
        h.source.startFailure = FlotsamError(.trgOs001, "tap refused")

        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.engine.status == .tapUnavailable(.trgOs001))
        #expect(await h.base.reportedCodes() == [.trgOs001])

        h.source.startFailure = nil
        h.runWatchdogPass()

        #expect(await eventually { h.engine.status == .running })
    }

    // MARK: AC-005-18 (FR-005-19)

    @Test func aDisabledTapIsReenabledItsWordClearedAndATrg003NoticeShown() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.engine.status == .running)

        // "zqxsi" is typed; the tap is disabled and re-enabled; "g" then Space would complete ";zqxsig" only if the
        // word had survived the disablement.
        h.source.type(";zqxsi")
        h.source.simulateDisable(.timeout)
        h.source.type("g")
        let decision = h.source.press(TriggerKeys.space, " ")

        #expect(h.source.reenableCount == 1)
        #expect(h.source.isHealthy)
        #expect(decision == .pass)
        #expect(await eventually { h.noticeCodes == [.trgOs003] })
        #expect(h.engine.status == .running)
        #expect(h.base.store.recorded.isEmpty)
    }

    @Test func theTriggerStillWorksAfterAReenable() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        h.source.simulateDisable(.userInput)

        h.source.type(Self.trigger)
        let decision = h.source.press(TriggerKeys.space, " ")

        #expect(decision == .consume)
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    @Test func threeDisablementsWithinSixtySecondsLatchTheTapOffWithAWarningDot() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(!h.engine.showsWarningDot)

        for _ in 0..<3 { h.source.simulateDisable() }

        #expect(await eventually { h.engine.status == .latchedOff })
        #expect(h.engine.showsWarningDot)
        #expect(!h.source.isInstalled)
        // Two re-enables; the third disablement is the one that latched.
        #expect(h.source.reenableCount == 2)

        // The watchdog does not bring a latched tap back.
        h.runWatchdogPass()
        await h.engine.watchdogTick()
        #expect(h.engine.status == .latchedOff)
        #expect(h.source.startCount == 1)
    }

    @Test func togglingTriggersOffAndOnRestoresALatchedTap() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        for _ in 0..<3 { h.source.simulateDisable() }
        #expect(await eventually { h.engine.status == .latchedOff })

        h.settings.set(false, for: SettingKeys.triggersEnabled)
        #expect(await eventually { h.engine.status == .off })
        #expect(!h.engine.showsWarningDot)

        h.settings.set(true, for: SettingKeys.triggersEnabled)
        #expect(await eventually { h.engine.status == .running })
        #expect(h.source.startCount == 2)
        #expect(h.source.isInstalled)
        // The history went with the latch: two more disablements are re-enabled, not latched.
        h.source.simulateDisable()
        h.source.simulateDisable()
        #expect(h.source.isHealthy)
        #expect(h.engine.status == .running)
    }

    @Test func aDisablementTheWatchdogFindsIsReenabledAndReported() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }

        h.source.disableSilently()
        #expect(!h.source.isHealthy)
        await h.engine.watchdogTick()

        #expect(h.source.reenableCount == 1)
        #expect(h.source.isHealthy)
        #expect(h.engine.status == .running)
        #expect(await h.base.reportedCodes() == [.trgOs003])
    }

    @Test func disablementsFoundByTheWatchdogCountTowardTheSameLimit() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }

        h.source.simulateDisable()
        h.source.disableSilently()
        await h.engine.watchdogTick()
        h.source.disableSilently()
        await h.engine.watchdogTick()

        #expect(h.engine.status == .latchedOff)
        #expect(!h.source.isInstalled)
    }

    @Test func aTapThatWillNotReenableIsReplacedByAFreshOne() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }

        h.source.reenableSucceeds = false
        h.source.disableSilently()
        await h.engine.watchdogTick()

        #expect(h.source.startCount == 2)
        #expect(h.source.isHealthy)
        #expect(h.engine.status == .running)
    }

    @Test func resumingFromSleepClearsTheWordAndReverifiesTheTapNow() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        h.source.type(";zqxsi")

        h.source.disableSilently()
        await h.engine.systemDidResume()
        h.source.type("g")
        let decision = h.source.press(TriggerKeys.space, " ")

        #expect(h.source.isHealthy)
        #expect(decision == .pass)
    }

    // MARK: FR-005-22

    @Test func aDeletedItemsTriggerStopsMatchingBeforeThePublishReturns() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.base.snapshot.policy.triggers.count == 1)

        h.bus.publish(.itemsDeleted([itemId]))

        // No await since the publish: the drop was inline, not scheduled.
        #expect(h.base.snapshot.policy.triggers.isEmpty)
        h.source.type(Self.trigger)
        #expect(h.source.press(TriggerKeys.space, " ") == .pass)
        // And with no trigger left the engine removes the tap.
        #expect(await eventually { h.engine.status == .idle })
        #expect(!h.source.isInstalled)
    }

    @Test func aDeleteOfAnotherItemLeavesTheTriggerAndTheTap() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }

        h.bus.publish(.itemsDeleted([UUID()]))
        await h.engine.watchdogTick()

        #expect(h.base.snapshot.policy.triggers.count == 1)
        #expect(h.engine.status == .running)
    }

    @Test func aBurstOfItemChangesCostsOneSnapshotRebuild() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        let before = h.bindings.callCount

        for _ in 0..<100 { h.bus.publish(.itemsChanged) }

        #expect(await eventually { h.bindings.callCount > before })
        // The loop could not run during the synchronous burst, so all 100 events folded into one queued rebuild.
        #expect(h.bindings.callCount == before + 1)
    }

    @Test func aFailedRebuildKeepsTheOldTriggersAndReportsTheError() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        h.bindings.result = .failure(FlotsamError(.stoDb001, "read failed"))

        h.bus.publish(.itemsChanged)

        #expect(await eventually { h.bindings.callCount >= 2 })
        #expect(await eventually { h.noticeCodes.contains(.stoDb001) })
        #expect(h.base.snapshot.policy.triggers.count == 1)
        #expect(h.engine.status == .running)
    }
}
