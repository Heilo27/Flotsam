import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamTriggers

/// An `ItemBindingSource` whose read can be held open. It captures the answer when the engine asks and returns that
/// captured answer only once the test calls `release`, the way a slow database read returns what it saw when it started.
final class HeldBindingSource: ItemBindingSource, @unchecked Sendable {
    private struct State {
        var next: ItemBindings
        var holding = false
        var held: [(answer: ItemBindings, continuation: CheckedContinuation<Void, Never>)] = []
        var started = 0
        var finished = 0
    }

    private let state: LockedValue<State>
    init(triggers: [UUID: String]) { state = LockedValue(State(next: ItemBindings(triggers: triggers))) }

    var started: Int { state.value.started }
    var finished: Int { state.value.finished }
    var heldCount: Int { state.value.held.count }

    func set(_ triggers: [UUID: String]) { state.withLock { $0.next = ItemBindings(triggers: triggers) } }
    func hold(_ on: Bool) { state.withLock { $0.holding = on } }

    func itemBindings() async -> FlotsamResult<ItemBindings> {
        let answer = state.withLock { state -> ItemBindings in
            state.started += 1
            return state.next
        }
        if state.value.holding {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                state.withLock { $0.held.append((answer, continuation)) }
            }
        }
        state.withLock { $0.finished += 1 }
        return .success(answer)
    }

    /// Lets every held read return the answer it captured.
    func release() {
        let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            let all = state.held.map(\.continuation)
            state.held = []
            return all
        }
        for continuation in held { continuation.resume() }
    }
}

/// Independent QA cases for `TriggerEngine`: inline delete against a rebuild in flight (FR-005-22), tap health counting
/// (FR-005-19, OC-5126) and the whole tap handler's cost (FR-005-21). Fake tap only: no event tap, no keystroke.
@MainActor
@Suite struct TriggerEngineAdversarialTests {
    private let oldId = UUID()
    private let newId = UUID()

    /// An engine over a held binding source, sharing the expander harness's fakes the way `EngineHarness` does.
    @MainActor private struct HeldHarness {
        let base = ExpanderHarness()
        let source = FakeKeyEventSource()
        let bindings: HeldBindingSource
        let bus = ItemEventBus()
        let engine: TriggerEngine

        init(triggers: [UUID: String]) {
            bindings = HeldBindingSource(triggers: triggers)
            let settings = SettingsStore(store: InMemoryKeyValueStore())
            settings.set(true, for: SettingKeys.triggersEnabled)
            engine = TriggerEngine(
                source: source, snapshot: base.snapshot, bindings: bindings, settings: settings, bus: bus,
                expander: base.expander, keyboard: base.environment, permissions: base.permissions,
                reporter: base.reporter, clock: GatedClock(), resetSignal: TriggerResetSignal(),
                ownBundleId: "com.example.flotsam")
        }
    }

    // MARK: FR-005-22: an inline delete racing a rebuild

    @Test func aTriggerSavedWhileAnUnrelatedDeleteLandsStillWorksOnceTheRebuildFinishes() async {
        // given ";old" bound and a rebuild reading ";old" and the newly saved ";new", when an unrelated item is deleted
        // before that read returns, then ";new" must still expand once the engine settles (AC-005-21, FR-005-22: the
        // delete drops only its own trigger).
        let h = HeldHarness(triggers: [oldId: ";old"])
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.base.snapshot.policy.triggers.count == 1)

        h.bindings.hold(true)
        h.bindings.set([oldId: ";old", newId: ";new"])
        h.bus.publish(.itemsChanged)  // the user saved ";new"
        #expect(await eventually { h.bindings.heldCount == 1 })
        h.bus.publish(.itemsDeleted([UUID()]))  // an item with no trigger is deleted meanwhile
        h.bindings.hold(false)
        h.bindings.release()
        #expect(await eventually { h.bindings.finished == 2 })

        // Settled: give any follow-up rebuild time to run, then read what the user would get.
        let installed = await eventually(timeout: .seconds(1)) { h.base.snapshot.policy.triggers.count == 2 }
        #expect(installed, "snapshot holds \(h.base.snapshot.policy.triggers.count) trigger(s), expected 2")
        // The saved trigger's expansion is what the user sees: ";new" Space must be swallowed.
        h.source.type(";new")
        let decision = h.source.press(TriggerKeys.space, " ")
        #expect(decision == .consume)
    }

    @Test func theSameSaveWithNoDeleteInTheWayInstallsTheNewTrigger() async {
        // The control for the test above: with no delete during the read, the rebuild lands and ";new" expands.
        let h = HeldHarness(triggers: [oldId: ";old"])
        await h.engine.start()
        defer { h.engine.stop() }

        h.bindings.hold(true)
        h.bindings.set([oldId: ";old", newId: ";new"])
        h.bus.publish(.itemsChanged)
        #expect(await eventually { h.bindings.heldCount == 1 })
        h.bindings.hold(false)
        h.bindings.release()

        #expect(await eventually { h.base.snapshot.policy.triggers.count == 2 })
        h.source.type(";new")
        #expect(h.source.press(TriggerKeys.space, " ") == .consume)
        #expect(await eventually { h.base.store.recorded == [newId] })
    }

    @Test func aDeleteThatArrivesWhileTheReadIsHeldStillRemovesItsOwnTriggerRightAway() async {
        // given a rebuild in flight that read ";old" before the delete, when the item bound to ";old" is deleted, then
        // ";old" stops expanding at once and the late read cannot bring it back.
        let h = HeldHarness(triggers: [oldId: ";old"])
        await h.engine.start()
        defer { h.engine.stop() }

        h.bindings.hold(true)
        h.bus.publish(.itemsChanged)
        #expect(await eventually { h.bindings.heldCount == 1 })
        h.bus.publish(.itemsDeleted([oldId]))
        #expect(h.base.snapshot.policy.triggers.count == 0)
        h.bindings.hold(false)
        h.bindings.release()
        #expect(await eventually { h.bindings.finished == 2 })
        try? await Task.sleep(for: .milliseconds(100))

        #expect(h.base.snapshot.policy.triggers.count == 0)
        #expect(h.source.type(";old").allSatisfy { $0 == .pass })
        #expect(h.source.press(TriggerKeys.space, " ") == .pass)
    }

    @Test func deletingTwoOfFiveTriggersLeavesExactlyTheOtherThreeExpanding() async {
        // given five triggers, when two are deleted in one event, then the three survivors expand (by identity), the two
        // deleted ones pass through, and nothing else changed.
        let ids = (0..<5).map { _ in UUID() }
        let texts = [";aa1", ";bb2", ";cc3", ";dd4", ";ee5"]
        let base = ExpanderHarness()
        let h = EngineHarness(triggers: Dictionary(uniqueKeysWithValues: zip(ids, texts)), base: base)
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(base.snapshot.policy.triggers.count == 5)

        h.bus.publish(.itemsDeleted([ids[1], ids[3]]))
        #expect(base.snapshot.policy.triggers.count == 3)

        var decisions: [String: KeyDecision] = [:]
        for text in texts {
            h.source.type(text)
            decisions[text] = h.source.press(TriggerKeys.space, " ")
        }
        #expect(decisions == [
            ";aa1": .consume, ";bb2": .pass, ";cc3": .consume, ";dd4": .pass, ";ee5": .consume,
        ])
    }

    @Test func aDeleteEventWithNoIdsChangesNothing() async {
        // given a bound trigger, when an itemsDeleted event carries an empty list, then the trigger still expands.
        let h = EngineHarness(triggers: [oldId: ";old"])
        await h.engine.start()
        defer { h.engine.stop() }

        h.bus.publish(.itemsDeleted([]))

        #expect(h.base.snapshot.policy.triggers.count == 1)
        h.source.type(";old")
        #expect(h.source.press(TriggerKeys.space, " ") == .consume)
    }

    // MARK: FR-005-19: tap health

    @Test func twoDisablementsReenableTwiceAndShowExactlyOneNotice() async {
        // given two tap disablements 0 s apart, when both are handled, then the tap was re-enabled twice and the Notice
        // list holds exactly one TRG-OS-003 (OC-5126: throttled to one per 60 s).
        let h = EngineHarness(triggers: [oldId: ";old"])
        await h.engine.start()
        defer { h.engine.stop() }

        h.source.simulateDisable()
        h.source.simulateDisable()

        #expect(await eventually { h.noticeCodes == [.trgOs003] })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.noticeCodes == [.trgOs003])
        #expect(h.source.reenableCount == 2)
        #expect(h.engine.status == .running)
    }

    @Test func aCallbackDisablementFollowedByAHealthyWatchdogPassIsCountedOnce() async {
        // given the callback re-enabled the tap each time, when the watchdog runs between disablements, then it adds no
        // count: only the third callback disablement latches (no double counting).
        let h = EngineHarness(triggers: [oldId: ";old"])
        await h.engine.start()
        defer { h.engine.stop() }

        h.source.simulateDisable()
        await h.engine.watchdogTick()
        h.source.simulateDisable()
        await h.engine.watchdogTick()
        #expect(h.engine.status == .running)
        #expect(h.source.isInstalled)

        h.source.simulateDisable()
        #expect(await eventually { h.engine.status == .latchedOff })
        #expect(!h.source.isInstalled)
        #expect(h.source.reenableCount == 2)
    }

    @Test func aLatchedTapStaysOffWhenTheDisablementsArriveSpreadPastTheWindowOnlyAfterTheyAreCountedAgain() async {
        // given two disablements, a 61 s wait, then a third, when the first has aged out, then the tap is not latched.
        let h = EngineHarness(triggers: [oldId: ";old"])
        await h.engine.start()
        defer { h.engine.stop() }

        h.source.simulateDisable()
        h.source.simulateDisable()
        h.clock.advance(61)
        h.source.simulateDisable()

        #expect(await eventually { h.noticeCodes.contains(.trgOs003) })
        #expect(h.engine.status == .running)
        #expect(h.source.isInstalled)
        #expect(h.source.reenableCount == 3)
    }

    // MARK: FR-005-21: the whole tap handler, not only the matcher

    @Test func theEngineTapHandlerStaysUnderOneMillisecondAtP99WithAThousandTriggersAndMatches() async {
        // given 1,000 triggers and a script that matches 1 word in 3, when each event goes through the engine's own tap
        // handler, then p99 per event is at most 1 ms (the handler also yields to the loop on a match).
        var triggers: [UUID: String] = [:]
        var texts: [String] = []
        for index in 0..<1_000 {
            let text = ";q\(index)"
            triggers[UUID()] = text
            texts.append(text)
        }
        let h = EngineHarness(triggers: triggers)
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.base.snapshot.policy.triggers.count == 1_000)

        var events: [KeyEvent] = []
        func key(_ code: UInt16, _ characters: String) {
            events.append(KeyEvent(kind: .keyDown, keyCode: code, characters: characters))
            events.append(KeyEvent(kind: .keyUp, keyCode: code, characters: characters))
        }
        var word = 0
        while events.count < 1_400 {
            let text = word % 3 == 0 ? texts[(word / 3) % texts.count] : "plain\(word)xyz"
            for ch in text { key(0, String(ch)) }
            key(TriggerKeys.space, " ")
            word += 1
        }
        for event in events.prefix(200) { h.source.send(event) }

        let clock = ContinuousClock()
        var samples: [Double] = []
        var consumed = 0
        for event in events.dropFirst(200).prefix(1_000) {
            var decision = KeyDecision.pass
            let elapsed = clock.measure { decision = h.source.send(event) }
            samples.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            if decision == .consume && event.kind == .keyDown { consumed += 1 }
        }

        #expect(samples.count == 1_000)
        #expect(consumed >= 15, "the script must match triggers, not only pass words")
        let sorted = samples.sorted()
        let p99 = sorted[Int((0.99 * Double(sorted.count)).rounded(.up)) - 1]
        #expect(p99 <= 0.001, "p99 \(p99 * 1000) ms")
    }
}
