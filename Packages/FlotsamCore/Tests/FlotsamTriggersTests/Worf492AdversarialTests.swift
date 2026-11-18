import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// Worf blind QA for TASK-492 (FR-005-11, FR-005-14 step 5, FR-005-20): the word buffer's length has one source, the
/// grapheme count of the buffer itself. Cap, empty-buffer Backspace and `triggerLength` must agree with it for every
/// key-event sequence, and no sequence may trap.
///
/// The fuzz model below is deliberately independent of the implementation: it keeps its own list of clusters, built from
/// tokens whose grapheme behaviour is fixed by construction (an ASCII or Thai base starts a cluster, a nonspacing mark
/// joins the previous cluster, a flag or ZWJ family is one cluster). Expected values are literals.
@Suite struct Worf492AdversarialTests {
    private let sig = UUID()
    private let long = UUID()
    private static let longTrigger = ";" + String(repeating: "a", count: 23)  // 24 characters
    private static let acute = "\u{0301}"
    private static let thaiBase = "\u{0E01}"
    private static let thaiMark = "\u{0E31}"
    private static let flag = "\u{1F1FA}\u{1F1F8}"
    private static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"

    private func harness() -> MatcherHarness {
        MatcherHarness(triggers: [sig: ";sig", long: Self.longTrigger])
    }

    // MARK: Fuzz model

    private enum Token: CustomStringConvertible {
        case base(String)  // one event, exactly one new cluster
        case multi(String, Int)  // one event delivering this many new clusters
        case mark(String)  // one event, joins the previous cluster (or is its own cluster when none)
        case backspace
        case boundary
        case clearing(String)  // a control-character event: not printable, so it ends the word
        case esc

        var description: String {
            switch self {
            case .base(let s): "base(\(s.unicodeScalars.map { String($0.value, radix: 16) }))"
            case .multi(let s, let n): "multi(\(s.unicodeScalars.count) scalars, \(n))"
            case .mark(let s): "mark(\(s.unicodeScalars.map { String($0.value, radix: 16) }))"
            case .backspace: "bksp"
            case .boundary: "space"
            case .clearing(let s): "clear(\(s.unicodeScalars.map { String($0.value, radix: 16) }))"
            case .esc: "esc"
            }
        }
    }

    private struct Model {
        var clusters: [String] = []
        var dead = false
        var matches = 0
        var cap25Deaths = 0
        mutating func clear() { clusters = []; dead = false }
    }

    private struct Outcome: Equatable {
        var matchedLength: Int?  // nil = pass
    }

    /// Applies one token to the matcher and to the model; returns a failure description or nil.
    private func apply(_ token: Token, h: MatcherHarness, model: inout Model, history: [Token]) -> String? {
        let cap = 24
        switch token {
        case .base(let s):
            _ = h.down(0, s)
            if !model.dead {
                if model.clusters.count + 1 > cap { model.clear(); model.dead = true; model.cap25Deaths += 1 } else { model.clusters.append(s) }
            }
        case .multi(let s, let n):
            _ = h.down(0, s)
            if !model.dead {
                if model.clusters.count + n > cap {
                    model.clear(); model.dead = true
                } else {
                    for ch in s { model.clusters.append(String(ch)) }  // ASCII only: one cluster per character
                }
            }
        case .mark(let s):
            _ = h.down(0, s)
            if !model.dead {
                if model.clusters.isEmpty { model.clusters.append(s) } else { model.clusters[model.clusters.count - 1] += s }
            }
        case .backspace:
            let r = h.down(TriggerKeys.backspace)
            if r != .pass { return "Backspace returned \(r)" }
            if model.dead { break }
            if model.clusters.isEmpty { model.dead = true } else { model.clusters.removeLast() }
        case .clearing(let s):
            _ = h.down(0, s)
            model.clear()
        case .esc:
            _ = h.down(53)
            model.clear()
        case .boundary:
            let r = h.space()
            let word = model.clusters.joined()
            let expectMatch = !model.dead && (word == ";sig" || word == Self.longTrigger)
            let wasDead = model.dead
            model.clear()
            switch r {
            case .matched(let m):
                model.matches += 1
                if !expectMatch { return "unexpected match of \(m.typedText), model dead=\(wasDead)" }
                let expectedLength = word == ";sig" ? 4 : 24
                if m.triggerLength != expectedLength { return "triggerLength \(m.triggerLength) != \(expectedLength)" }
                // The Backspace count is what it takes to empty the same word: replay the prefix and count.
                let needed = backspacesToEmpty(history)
                if needed != m.triggerLength { return "triggerLength \(m.triggerLength) but \(needed) Backspaces empty the word" }
            case .pass:
                if expectMatch { return "expected a match of \(word), got pass" }
            default:
                return "unexpected result \(r)"
            }
        }
        if h.matcher.holdsNoCharacters != model.clusters.isEmpty {
            return "holdsNoCharacters \(h.matcher.holdsNoCharacters) but model holds \(model.clusters.count) clusters"
        }
        return nil
    }

    /// Replays `tokens` on a fresh matcher, then sends Backspaces until the word is empty; returns how many it took.
    private func backspacesToEmpty(_ tokens: [Token]) -> Int {
        let h = harness()
        var scratch = Model()
        for t in tokens { _ = apply(t, h: h, model: &scratch, history: []) }
        var n = 0
        while !h.matcher.holdsNoCharacters && n < 1000 {
            _ = h.down(TriggerKeys.backspace)
            n += 1
        }
        return n
    }

    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func randomTokens(_ rng: inout SplitMix, mode: Int) -> [Token] {
        let sigChars = [";", "s", "i", "g"]
        let noise: [Token] = [
            .base("a"), .base("b"), .base("e\u{0301}"), .base(Self.thaiBase), .base(Self.flag), .base(Self.family),
            .base("\u{1F600}"), .mark(Self.acute), .mark(Self.thaiMark), .multi("xyz", 3), .multi("ab", 2),
            .backspace, .backspace, .clearing("\r\n"), .clearing("\r"), .clearing("\n"), .esc,
        ]
        var out: [Token] = []
        let length = Int.random(in: 20...90, using: &rng)
        for _ in 0..<length {
            let roll = Int.random(in: 0..<100, using: &rng)
            switch mode {
            case 0:  // noise heavy, with whole ";sig" words dropped in
                if roll < 15 { out += sigChars.map { .base($0) } }
                else { out.append(roll < 27 ? .boundary : noise.randomElement(using: &rng)!) }
            case 1:  // tries to type ";sig" through noise
                if roll < 20 { out += sigChars.map { .base($0) } }
                else if roll < 40 { out.append(.base(sigChars.randomElement(using: &rng)!)) }
                else if roll < 52 { out.append(.boundary) }
                else { out.append(noise.randomElement(using: &rng)!) }
            case 2:  // marks and Backspace storms around the cap
                if roll < 50 { out.append(.base("a")) }
                else if roll < 70 { out.append(.mark(Self.acute)) }
                else if roll < 88 { out.append(.backspace) }
                else if roll < 94 { out.append(.base(";")) }
                else { out.append(.boundary) }
            default:  // types the 24-grapheme trigger with marks and Backspaces interleaved
                if roll < 6 { out += [Token.base(";")] + Array(repeating: Token.base("a"), count: 23) }
                else if roll < 55 { out.append(.base(roll % 2 == 0 ? "a" : ";")) }
                else if roll < 75 { out.append(.mark(Self.thaiMark)) }
                else if roll < 90 { out.append(.backspace) }
                else { out.append(.boundary) }
            }
        }
        return out
    }

    // OC-WORF492-01: given random key-event sequences (combining marks, flags, ZWJ, CRLF, Backspace storms, over-cap
    // events), when each is replayed, then nothing traps, the matcher holds exactly what the model holds after every
    // event, every match has the literal trigger length, and that length is the number of Backspaces that empty the word.
    @Test(arguments: [0, 1, 2, 3])
    func fuzzedSequencesNeverTrapAndTriggerLengthEqualsBackspacesNeeded(mode: Int) {
        var rng = SplitMix(state: UInt64(0xF492_0000 + mode))
        var matches = 0
        var passes = 0
        for iteration in 0..<1500 {
            let tokens = randomTokens(&rng, mode: mode)
            let h = harness()
            var model = Model()
            var history: [Token] = []
            for token in tokens {
                if let failure = apply(token, h: h, model: &model, history: history) {
                    Issue.record("mode \(mode) iteration \(iteration): \(failure); sequence \(history.map(\.description) + [token.description])")
                    return
                }
                if case .boundary = token {} else { history.append(token) }
                if case .boundary = token { history = [] }
                if case .clearing = token { history = [] }
                if case .esc = token { history = [] }
            }
            // Final probe: Backspaces needed equals the model's cluster count, then one more kills the word.
            let probe = harness()
            var scratch = Model()
            for t in tokens { _ = apply(t, h: probe, model: &scratch, history: []) }
            let expected = scratch.clusters.count
            var n = 0
            while !probe.matcher.holdsNoCharacters && n < 1000 { _ = probe.down(TriggerKeys.backspace); n += 1 }
            if n != expected { Issue.record("mode \(mode) iteration \(iteration): \(n) Backspaces to empty, model says \(expected)"); return }
            matches += model.matches
            passes += model.cap25Deaths
        }
        if mode != 2 { #expect(matches > 50, "mode \(mode): only \(matches) real matches") }  // the fuzz really reached matches (mode 2 targets the cap)
        if mode >= 2 { #expect(passes > 0, "mode \(mode): never reached the 25th grapheme") }
    }

    // OC-WORF492-02: the fuzz must be able to see a match (guards against a fuzz that only ever passes).
    @Test func theFuzzGeneratorReachesRealMatchesWithBackspaceNoise() throws {
        let h = harness()
        for ch in [";", "s", "x", "\u{0301}"] { _ = h.down(0, ch) }
        _ = h.down(TriggerKeys.backspace)  // removes "x" plus its mark
        for ch in ["i", "g"] { _ = h.down(0, ch) }
        let m = try #require(h.space().match)
        #expect(m.typedText == ";sig")
        #expect(m.triggerLength == 4)
    }

    // MARK: Cap boundaries (FR-005-11: 24 live, 25 dead)

    // OC-WORF492-03: given 23, 24 and 25 graphemes, when the boundary arrives, then 24 matches and 25 does not.
    @Test func exactly24GraphemesMatchesAndTriggerLengthIs24() throws {
        let h = harness()
        h.type(Self.longTrigger)
        #expect(!h.matcher.holdsNoCharacters)
        let m = try #require(h.space().match)
        #expect(m.triggerLength == 24)
        #expect(m.typedText == Self.longTrigger)
    }

    @Test func the25thGraphemeEmptiesTheBufferAtOnceAndNothingMatchesAfterBackspace() {
        let h = harness()
        h.type(Self.longTrigger)
        h.type("a")
        #expect(h.matcher.holdsNoCharacters)  // dead word holds nothing
        for _ in 0..<30 { _ = h.down(TriggerKeys.backspace) }
        h.type(Self.longTrigger)
        #expect(h.matcher.holdsNoCharacters)  // still dead: appends are ignored
        #expect(h.space() == .pass)
        h.type(Self.longTrigger)
        #expect(h.space().match?.triggerLength == 24)  // the boundary revived it
    }

    // OC-WORF492-04: a mark at the cap joins the 24th grapheme: still live, and Backspace removes the whole cluster.
    @Test func markAt24StaysLiveAndOneBackspaceDropsTheClusterNotTwo() throws {
        let h = harness()
        h.type(Self.longTrigger)
        for _ in 0..<10 { _ = h.down(0, Self.acute) }
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.down(TriggerKeys.backspace)
        h.type("a")
        let m = try #require(h.space().match)
        #expect(m.triggerLength == 24)
    }

    // OC-WORF492-05: a single event over the cap, from empty and from a partly typed word.
    @Test func singleEventOf25GraphemesFromEmptyKillsTheWord() {
        let h = harness()
        _ = h.down(0, String(repeating: "a", count: 25))
        #expect(h.matcher.holdsNoCharacters)
        h.type("a")
        #expect(h.space() == .pass)
    }

    @Test func singleEventOf24GraphemesFromEmptyIsLive() {
        let h = harness()
        _ = h.down(0, Self.longTrigger)
        #expect(!h.matcher.holdsNoCharacters)
        #expect(h.space().match?.triggerLength == 24)
    }

    @Test func singleEventThatTakesTheWordFrom23To25KillsItAndOneThatReaches24Keeps() {
        let h = harness()
        h.type(String(repeating: "a", count: 23))
        _ = h.down(0, "bc")  // 25
        #expect(h.matcher.holdsNoCharacters)
        _ = h.space()
        h.type(String(repeating: "a", count: 23))
        _ = h.down(0, "b")  // 24
        #expect(!h.matcher.holdsNoCharacters)
    }

    @Test func aHugeSingleEventDoesNotTrapAndKillsTheWord() {
        let h = harness()
        _ = h.down(0, String(repeating: "\u{1F468}\u{200D}\u{1F469}", count: 5000))
        #expect(h.matcher.holdsNoCharacters)
        _ = h.down(TriggerKeys.backspace)
        #expect(h.space() == .pass)
    }

    // OC-WORF492-06: 24 emoji clusters (many scalars each) are within the cap; 25 are not. Cap counts graphemes.
    @Test func capCountsGraphemesNotScalarsForFlagsAndZwjFamilies() {
        let live = harness()
        for _ in 0..<24 { _ = live.down(0, Self.family) }
        #expect(!live.matcher.holdsNoCharacters)
        for _ in 0..<24 { _ = live.down(TriggerKeys.backspace) }
        #expect(live.matcher.holdsNoCharacters)

        let dead = harness()
        for _ in 0..<25 { _ = dead.down(0, Self.flag) }
        #expect(dead.matcher.holdsNoCharacters)
    }

    // MARK: The reported trap and its neighbours

    // OC-WORF492-07: the reported sequence, and every variant of base/mark/Backspace counts around it.
    @Test(arguments: 0...6)
    func thaiBaseThenMarkThenBackspacesNeverTrap(extraBackspaces: Int) {
        let h = harness()
        _ = h.down(0, Self.thaiBase)
        _ = h.down(0, Self.thaiMark)
        for _ in 0..<(1 + extraBackspaces) { #expect(h.down(TriggerKeys.backspace) == .pass) }
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)  // dead or empty: no match either way
        h.type(";sig")
        #expect(h.space().match?.triggerLength == 4)
    }

    @Test func aLoneMarkOnAnEmptyWordIsOneCharacterAndOneBackspaceEmptiesIt() {
        let h = harness()
        _ = h.down(0, Self.thaiMark)
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.down(TriggerKeys.backspace)
        #expect(h.matcher.holdsNoCharacters)
        _ = h.down(TriggerKeys.backspace)  // empty buffer: must not trap, kills the word
        h.type(";sig")
        #expect(h.space() == .pass)
    }

    @Test func aBackspaceStormOnAnEmptyAndOnADeadWordNeverTrapsAndTheBoundaryRevives() {
        let h = harness()
        for _ in 0..<2000 { #expect(h.down(TriggerKeys.backspace) == .pass) }
        h.type(";sig")
        #expect(h.space() == .pass)  // dead from the first Backspace
        h.type(";sig")
        #expect(h.space().match?.triggerLength == 4)
    }

    // OC-WORF492-08: CRLF and lone CR / LF are control characters: they end the word and never become buffer content.
    @Test(arguments: ["\r\n", "\r", "\n"])
    func lineBreakEventsEndTheWordAndLeaveNoBufferedCharacters(text: String) {
        let h = harness()
        h.type(";si")
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.down(0, text)
        #expect(h.matcher.holdsNoCharacters)
        _ = h.down(TriggerKeys.backspace)  // empty buffer after a clear: dead, no trap
        h.type("g")
        #expect(h.space() == .pass)
    }

    // OC-WORF492-09: a dead word stays dead through marks, flags and Backspaces until a boundary.
    @Test func aDeadWordIgnoresMarksAndBackspacesUntilTheBoundary() {
        let h = harness()
        h.type(Self.longTrigger + "z")
        _ = h.down(0, Self.acute)
        _ = h.down(0, Self.flag)
        _ = h.down(TriggerKeys.backspace)
        #expect(h.matcher.holdsNoCharacters)
        h.type(";sig")
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space().match?.triggerLength == 4)
    }

    // OC-WORF492-10: Backspace removes exactly one cluster for each event shape, so N events of one cluster take N Backspaces.
    @Test(arguments: [Self.flag, Self.family, "e\u{0301}", "\u{0E01}\u{0E31}\u{0E49}", "\u{1F600}"])
    func nClustersTakeExactlyNBackspacesToEmpty(cluster: String) {
        for n in [1, 2, 7, 24] {
            let h = harness()
            for _ in 0..<n { _ = h.down(0, cluster) }
            for step in 0..<n {
                #expect(!h.matcher.holdsNoCharacters, "n=\(n) emptied after \(step) Backspaces")
                _ = h.down(TriggerKeys.backspace)
            }
            #expect(h.matcher.holdsNoCharacters)
        }
    }
}
