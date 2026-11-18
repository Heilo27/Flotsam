import Foundation
import Testing
import FlotsamBase
import FlotsamPaste
import FlotsamStorage
@testable import FlotsamTriggers

// TASK-432 blind QA, FR-000-11 "trigger match": yes/no only. A suppressed trigger logs matched=false once; a typed word
// that is no trigger logs nothing (decided on the tap thread, FR-005-21); an expansion logs matched=true; no typed
// text reaches the line.

@MainActor
@Suite struct Worf432bTriggerTests {
    private static let trigger = ";zqxwolf"
    private let itemId = ExpanderHarness.itemId

    /// The stock EngineHarness engine has no log sink, so build the engine from its parts with the recording sink.
    @MainActor private struct Rig {
        let h: EngineHarness
        let engine: TriggerEngine
        var source: FakeKeyEventSource { h.source }
        var base: ExpanderHarness { h.base }
        func start() async { await engine.start() }
        func stop() { engine.stop() }
    }

    private func harness() -> Rig {
        let base = ExpanderHarness(content: .success(ItemContent(kind: .text, plainText: "bodyzqx", representations: [], members: [])))
        let h = EngineHarness(triggers: [itemId: Self.trigger], base: base)
        let engine = TriggerEngine(
            source: h.source, snapshot: base.snapshot, bindings: h.bindings, settings: h.settings, bus: h.bus,
            expander: base.expander, keyboard: base.environment, permissions: base.permissions, reporter: base.reporter,
            clock: h.clock, resetSignal: h.resetSignal, ownBundleId: "com.example.flotsam", pollTick: h.pollTick,
            sink: base.sink)
        return Rig(h: h, engine: engine)
    }

    private func matchedTexts(_ h: Rig) -> [String] {
        h.base.sink.records.filter { $0.headline == "trigger.matched" }.map(\.publicText)
    }

    /// OC-432-50. Given a trigger typed in an excluded app, when Space ends it, then the key passes through and
    /// exactly one `trigger.matched outcome=noMatch` line is logged at .info. Red if report() drops the callsite or
    /// logs `true`.
    @Test func oc43250_suppressedTriggerLogsMatchedFalseOnce() async {
        let h = harness()
        await h.start()
        defer { h.stop() }
        h.base.snapshot.setExcludedApps(["com.example.editor"])

        h.source.type(Self.trigger)
        #expect(h.source.press(TriggerKeys.space, " ") == .pass)

        #expect(await eventually { h.base.sink.allText.contains("TRG-POL-002") })
        #expect(matchedTexts(h) == ["trigger.matched outcome=noMatch"])
        #expect(h.base.sink.records.filter { $0.headline == "trigger.matched" }.allSatisfy { $0.level == .info })
    }

    /// OC-432-51. Given a trigger expanded in an ordinary app, then exactly one `matched=true` line and no `false`.
    @Test func oc43251_expandedTriggerLogsMatchedTrueOnly() async {
        let h = harness()
        await h.start()
        defer { h.stop() }

        h.source.type(Self.trigger)
        #expect(h.source.press(TriggerKeys.space, " ") == .consume)

        #expect(await eventually { h.base.store.recorded == [itemId] })
        #expect(matchedTexts(h) == ["trigger.matched outcome=matched"])
    }

    /// OC-432-52 (negative). Given an ordinary word that is not a trigger, then the key passes and nothing named
    /// trigger.matched is logged (no I/O for every typed word). Red if a callsite is added for the no-match path.
    @Test func oc43252_nonTriggerWordLogsNothing() async {
        let h = harness()
        await h.start()
        defer { h.stop() }

        h.source.type("hello")
        #expect(h.source.press(TriggerKeys.space, " ") == .pass)
        // Let any (wrong) async report run.
        h.source.type("again")
        #expect(h.source.press(TriggerKeys.space, " ") == .pass)

        #expect(await eventually { true })
        #expect(matchedTexts(h).isEmpty)
        #expect(h.base.sink.records.isEmpty)
    }

    /// OC-432-53 (privacy). Given suppressed and expanded triggers, then no log line contains the typed trigger text or
    /// the item body.
    @Test func oc43253_noTypedTextOrBodyInTheMatchLines() async {
        let h = harness()
        await h.start()
        defer { h.stop() }
        h.source.type(Self.trigger)
        #expect(h.source.press(TriggerKeys.space, " ") == .consume)
        #expect(await eventually { h.base.store.recorded == [itemId] })
        h.base.snapshot.setExcludedApps(["com.example.editor"])
        h.source.type(Self.trigger)
        _ = h.source.press(TriggerKeys.space, " ")
        #expect(await eventually { self.matchedTexts(h).count == 2 })

        let all = h.base.sink.allText
        #expect(!all.contains("zqx"))
        #expect(!all.contains("body"))
    }
}
