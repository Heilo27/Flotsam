import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// Independent checks for TASK-396 (hosting the engine in the app): the frontmost-change entry point the app calls
/// from `NSWorkspace.didActivateApplicationNotification` (FR-005-11), and the status callback the menu-bar warning dot
/// is driven by (FR-005-19). Fake tap only: no real event tap, no keystroke.
@MainActor
@Suite struct TriggerHostingWorfTests {
    private static let trigger = ";zqxsig"
    private let itemId = ExpanderHarness.itemId

    private func harness() -> EngineHarness {
        EngineHarness(triggers: [itemId: Self.trigger])
    }

    /// Statuses delivered to `onStatusChange`, paired with the dot value the app would read at that moment.
    private final class StatusLog {
        var entries: [(status: TriggerEngineStatus, dot: Bool)] = []
    }

    private func record(_ h: EngineHarness) -> StatusLog {
        let log = StatusLog()
        h.engine.onStatusChange = { [engine = h.engine] status in
            log.entries.append((status, engine.showsWarningDot))
        }
        return log
    }

    // MARK: FR-005-11 frontmost change (OC-5xxx AC-005-10: no expansion across apps)

    // Red if `frontmostApplicationDidChange` stops clearing the word (e.g. body emptied or the call unwired).
    @Test func aFrontmostChangeMidWordStopsTheTriggerFromExpanding() async {
        // given: ";zqxsi" typed, one character short of the trigger
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        h.source.type(";zqxsi")

        // when: the frontmost application changes, then the rest of the word and a boundary arrive
        h.engine.frontmostApplicationDidChange()
        h.source.type("g")
        let decision = h.source.press(TriggerKeys.space, " ")

        // then: the word was cleared, so nothing expands and the space goes through
        #expect(decision == .pass)
        #expect(h.base.store.recorded.isEmpty)
    }

    // The control for the test above: without the change the identical keystrokes DO expand, so the test above can
    // only be red-then-green through the reset, not through a broken fixture.
    @Test func theSameKeystrokesWithoutAFrontmostChangeExpand() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }

        h.source.type(";zqxsi")
        h.source.type("g")
        let decision = h.source.press(TriggerKeys.space, " ")

        #expect(decision == .consume)
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    // Boundary: a change BEFORE the word starts must not poison the word typed after it (no stuck reset).
    @Test func aFrontmostChangeBeforeTheWordLeavesTheNextWordLive() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }

        h.engine.frontmostApplicationDidChange()
        h.source.type(Self.trigger)
        let decision = h.source.press(TriggerKeys.space, " ")

        #expect(decision == .consume)
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    // One signal clears one word: a second word typed after the change expands (the reset is consumed, not sticky).
    @Test func afterAFrontmostChangeAFreshFullWordExpandsExactlyOnce() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        h.source.type(Self.trigger)  // a complete trigger, waiting for its boundary
        h.engine.frontmostApplicationDidChange()
        #expect(h.source.press(TriggerKeys.space, " ") == .pass)  // the change cleared it; boundary consumes the reset

        h.source.type(Self.trigger)
        #expect(h.source.press(TriggerKeys.space, " ") == .consume)

        #expect(await eventually { h.base.store.recorded == [itemId] })
        #expect(h.base.store.recorded.count == 1)
    }

    // A frontmost change while no tap exists must not crash or prompt for anything (engine not started).
    @Test func aFrontmostChangeWithNoTapInstalledIsHarmless() async {
        let h = EngineHarness(triggers: [:])
        await h.engine.start()
        defer { h.engine.stop() }

        h.engine.frontmostApplicationDidChange()

        #expect(h.engine.status == .idle)
        #expect(h.source.startCount == 0)
        #expect(h.base.permissions.requested.isEmpty)
    }

    // MARK: FR-005-19 warning dot driven by status changes

    // Red if the engine stops calling onStatusChange on a latch, or showsWarningDot is not true by then.
    @Test func theStatusCallbackFiresWithTheDotSetWhenTheTapLatches() async {
        let h = harness()
        let log = record(h)
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(await eventually { h.engine.status == .running })

        for _ in 0..<3 { h.source.simulateDisable() }
        #expect(await eventually { h.engine.status == .latchedOff })

        let latchEntries = log.entries.filter { $0.status == .latchedOff }
        #expect(latchEntries.count == 1)
        #expect(latchEntries.allSatisfy { $0.dot })
        // Every non-latched status reported so far had the dot clear.
        #expect(log.entries.filter { $0.status != .latchedOff }.allSatisfy { !$0.dot })
    }

    // Boundary 2 < limit 3: two disablements re-enable and never raise the dot or leave .running.
    @Test func twoDisablementsNeverRaiseTheDot() async {
        let h = harness()
        let log = record(h)
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(await eventually { h.engine.status == .running })

        h.source.simulateDisable()
        h.source.simulateDisable()
        await h.engine.watchdogTick()

        #expect(h.engine.status == .running)
        #expect(!h.engine.showsWarningDot)
        #expect(log.entries.allSatisfy { !$0.dot })
        #expect(h.source.reenableCount == 2)
    }

    // The dot clears on recovery, and the app is told at the moment it clears (not only at the moment it sets).
    @Test func theStatusCallbackClearsTheDotWhenTriggersAreToggledOffThenRunsAgain() async {
        let h = harness()
        let log = record(h)
        await h.engine.start()
        defer { h.engine.stop() }
        for _ in 0..<3 { h.source.simulateDisable() }
        #expect(await eventually { h.engine.status == .latchedOff })

        h.settings.set(false, for: SettingKeys.triggersEnabled)
        #expect(await eventually { h.engine.status == .off })
        h.settings.set(true, for: SettingKeys.triggersEnabled)
        #expect(await eventually { h.engine.status == .running })

        let statuses = log.entries.map(\.status)
        let latchIndex = statuses.firstIndex(of: .latchedOff)
        let offIndex = statuses.lastIndex(of: .off)
        #expect(latchIndex != nil && offIndex != nil && latchIndex! < offIndex!)
        // After the latch the sequence is exactly off then running, each delivered once, dot clear on both.
        #expect(Array(statuses[(latchIndex! + 1)...]) == [.off, .running])
        #expect(log.entries[(latchIndex! + 1)...].allSatisfy { !$0.dot })
        #expect(!h.engine.showsWarningDot)
    }

    // A steady latched state is not re-announced on every watchdog pass (no icon churn).
    @Test func watchdogPassesWhileLatchedDoNotRepeatTheStatusCallback() async {
        let h = harness()
        let log = record(h)
        await h.engine.start()
        defer { h.engine.stop() }
        for _ in 0..<3 { h.source.simulateDisable() }
        #expect(await eventually { h.engine.status == .latchedOff })
        let before = log.entries.count

        await h.engine.watchdogTick()
        await h.engine.watchdogTick()

        #expect(log.entries.count == before)
        #expect(h.engine.showsWarningDot)
    }

    // FR-005-19: "the menu-bar icon warning dot stays set" while latched. Revoking a permission while latched moves
    // the status to .inert, but the latch (TapHealth) is still held, so the dot must stay set.
    @Test func theDotStaysSetWhileLatchedEvenIfAPermissionIsRevoked() async {
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        for _ in 0..<3 { h.source.simulateDisable() }
        #expect(await eventually { h.engine.status == .latchedOff })

        h.base.permissions.set(.inputMonitoring, granted: false)
        await h.engine.watchdogTick()

        #expect(h.engine.showsWarningDot)
    }
}
