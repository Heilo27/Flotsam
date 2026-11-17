import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamTriggers

/// FR-005-21 (AC-005-20). Measured in a debug build on a shared machine, so a pass is a conservative one: the budget is
/// the spec's, not a looser one.
@MainActor
@Suite struct TriggerPerformanceTests {
    /// The value at the given percentile (nearest rank) of `samples`.
    private func percentile(_ p: Double, of samples: [Double]) -> Double {
        let sorted = samples.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, min(sorted.count - 1, rank))]
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// AC-005-20, first half: 1,000 scripted key events with 100 triggers defined; p99 of the callback is at most 1 ms.
    @Test func theTapCallbackIsUnderOneMillisecondAtP99With100Triggers() {
        var triggers: [UUID: String] = [:]
        for index in 0..<100 { triggers[UUID()] = ";t\(String(format: "%03d", index))" }
        let triggerTexts = Array(triggers.values)
        let h = MatcherHarness(triggers: triggers)

        // The script: a trigger, then a non-trigger word, then a backspace-edited word, each ended with Space.
        // Every key goes down and up, as the tap sees it.
        var events: [KeyEvent] = []
        func key(_ code: UInt16, _ characters: String) {
            events.append(KeyEvent(kind: .keyDown, keyCode: code, characters: characters))
            events.append(KeyEvent(kind: .keyUp, keyCode: code, characters: characters))
        }
        var word = 0
        while events.count < 1_200 {
            let text: String
            switch word % 3 {
            case 0: text = triggerTexts[(word / 3) % triggerTexts.count]
            case 1: text = "plainword\(word)"
            default: text = ";t0\(word % 10)x"
            }
            for ch in text { key(0, String(ch)) }
            if word % 3 == 2 { key(TriggerKeys.backspace, "") }
            key(TriggerKeys.space, " ")
            word += 1
        }

        // Warm up on the first 200 events, then time the next 1,000 (a first call pays for lazy setup; the callback
        // budget is for steady state).
        for event in events.prefix(200) { _ = h.matcher.process(event) }
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(1_000)
        var matches = 0
        for event in events.dropFirst(200).prefix(1_000) {
            var result = MatcherResult.pass
            let elapsed = clock.measure { result = h.matcher.process(event) }
            samples.append(seconds(elapsed))
            if case .matched = result { matches += 1 }
        }

        #expect(samples.count == 1_000)
        // The script is not vacuous: it matched triggers, not only passed words through.
        #expect(matches >= 15)
        let p99 = percentile(0.99, of: samples)
        #expect(p99 <= 0.001, "p99 \(p99 * 1000) ms")
    }

    /// AC-005-20, second half: over 50 expansions of a 10 KB item, boundary key to the ⌘V post is p95 <= 150 ms. The
    /// test clock does not wait, so each sample is the real compute time to the post plus the nominal sleeps the
    /// sequence asked for before it, which is what a real clock would have spent.
    @Test func boundaryKeyToPasteIsUnderOneFiftyMillisecondsAtP95ForA10KBItem() async {
        let body = String(repeating: "0123456789abcdef", count: 640)  // 10,240 characters
        let h = ExpanderHarness(
            content: .success(ItemContent(kind: .text, plainText: body, representations: [], members: [])))
        let clock = ContinuousClock()
        var samples: [Double] = []
        var started = clock.now
        var nominalAtPaste = 0.0
        var pasted = false
        h.keys.onAction = {
            guard !pasted, h.keys.actions.last == .paste else { return }
            pasted = true
            samples.append(self.seconds(clock.now - started))
            nominalAtPaste = h.clock.slept.reduce(0) { $0 + self.seconds($1) }
        }

        var nominalBefore = 0.0
        for _ in 0..<50 {
            pasted = false
            nominalBefore = h.clock.slept.reduce(0) { $0 + self.seconds($1) }
            started = clock.now
            let outcome = await h.expander.expand(h.match())
            #expect(outcome == .expanded)
            #expect(pasted)
            samples[samples.count - 1] += nominalAtPaste - nominalBefore
        }

        #expect(samples.count == 50)
        // The sequence does include a real wait (the settle pause), so the measurement is not just compute time.
        #expect(samples.allSatisfy { $0 >= seconds(PasteTiming.settle) })
        let p95 = percentile(0.95, of: samples)
        #expect(p95 <= 0.150, "p95 \(p95 * 1000) ms")
    }
}
