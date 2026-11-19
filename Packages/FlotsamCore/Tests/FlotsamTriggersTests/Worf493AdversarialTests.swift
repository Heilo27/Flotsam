import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// Worf blind QA for TASK-493 (FR-005-11 / AC-005-10, Ryan's ruling 2026-11-18: non-ASCII kills the word).
///
/// Oracle: OC-5148 (the Thai repro), OC-5149 (the word stays dead through Backspace), OC-5150 (the next word after a
/// boundary matches). Every expectation below is a literal. Each test names the mutation of `TriggerMatcher.append`
/// or `backspace` that turns it red.
@Suite struct Worf493AdversarialTests {
    private let ab = UUID()
    private let thai = "\u{0E01}"
    private let thaiMark = "\u{0E31}"
    private let backspace = TriggerKeys.backspace

    private func harness(excluded: Set<String> = []) -> MatcherHarness {
        MatcherHarness(triggers: [ab: ":ab"], excluded: excluded)
    }

    // MARK: OC-5148 the Thai repro, through the engine

    // OC-5148: given trigger `:ab`, when `:ab`, ก, a Thai mark, Backspace, Space are typed through the tap, then every
    // key passes, nothing is pasted, nothing is posted (no Backspaces, no text) and the item is not counted; the next
    // `:ab` Space expands. Red if the dead flag is dropped, or Backspace revives the word.
    @MainActor
    @Test func oc5148ThaiReproThroughTheEngineDeletesAndPostsNothing() async {
        let itemId = ExpanderHarness.itemId
        let h = EngineHarness(triggers: [itemId: ":ab"])
        await h.engine.start()
        defer { h.engine.stop() }

        h.source.type(":ab")
        h.source.type(thai)
        h.source.type(thaiMark)
        let backspaceDecision = h.source.press(backspace)
        let spaceDecision = h.source.press(TriggerKeys.space, " ")

        #expect(backspaceDecision == .pass)
        #expect(spaceDecision == .pass)  // the Space reaches the app, so it is typed, not swallowed
        #expect(h.base.keys.actions.isEmpty)  // no Backspace presses, no re-typed text, no paste
        #expect(h.base.pasteboard.writes.isEmpty)
        #expect(h.base.store.recorded.isEmpty)

        // the very next word after that boundary matches, and is counted exactly once
        let next = h.source.type(":ab") + [h.source.press(TriggerKeys.space, " ")]
        #expect(next == [.pass, .pass, .pass, .consume])
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    // MARK: OC-5149 the word stays dead through Backspace

    // OC-5149: given ASCII text of every length 0...4 then one non-ASCII event, when 0...8 Backspaces and a retyped
    // `:ab` follow, then Space matches nothing. The retype is the point: the dead flag, not an empty buffer, is what
    // blocks it. Red if the non-ASCII branch only clears the word (live, empty) instead of killing it, or Backspace
    // clears the dead flag.
    @Test(arguments: [":", ":a", ":ab", ":abc", "hello"], [0, 1, 2, 3, 8])
    func nonAsciiThenBackspacesThenRetypedTriggerNeverMatches(prefix: String, backspaces: Int) {
        let h = harness()
        h.type(prefix)
        _ = h.down(0, thaiMark)
        for _ in 0..<backspaces { #expect(h.down(backspace) == .pass) }
        h.type(":ab")
        #expect(h.space() == .pass, "\(prefix) + mark + \(backspaces) Backspaces")
    }

    // OC-5149: no Backspace at all. A word that was ":ab" typed after the non-ASCII character, with the field
    // untouched, must not match either: the buffer cannot know what the field holds. Red if the non-ASCII branch
    // returns without setting `isDead` (the empty buffer would then take ":ab" and match).
    @Test(arguments: ["\u{00E9}", "\u{0301}", "\u{0E01}", "\u{0E01}\u{0E31}", "\u{1F600}", "\u{4E2D}"])
    func nonAsciiThenAsciiTriggerWithoutAnyBackspaceNeverMatches(character: String) {
        let h = harness()
        _ = h.down(0, character)
        h.type(":ab")
        #expect(h.space() == .pass)

        let mid = harness()
        mid.type(":")
        _ = mid.down(0, character)
        mid.type("ab")
        #expect(mid.space() == .pass)
    }

    // OC-5149: the dead flag survives key-ups, auto-repeats, Shift and Caps Lock typing, and Backspace auto-repeat.
    @Test func theDeadWordSurvivesKeyUpsAutoRepeatsAndShiftedTyping() {
        let h = harness()
        h.type(":ab")
        _ = h.down(0, thai)
        _ = h.up(0)
        for _ in 0..<5 { _ = h.down(backspace, repeat: true) }
        _ = h.down(0, "a", flags: [.shift], repeat: true)
        h.type(":AB", flags: [.shift])
        h.type(":ab", flags: [.capsLock])
        #expect(h.space() == .pass)
    }

    // OC-5149: a non-ASCII event that carries ASCII too. Whatever position the non-ASCII scalar has in one event, the
    // word dies. Red if only the first, or only the last, scalar of the event is checked.
    @Test(arguments: ["a\u{0301}", "\u{00E9}b", "ab\u{00E9}", "a\u{00E9}b", "a\u{0E01}", "\u{0E01}a", ":ab\u{1F600}"])
    func aSingleEventMixingAsciiAndNonAsciiKillsTheWord(event: String) {
        let h = harness()
        h.type(":a")
        _ = h.down(0, event)
        #expect(h.matcher.holdsNoCharacters)
        h.type(":ab")
        #expect(h.space() == .pass)
    }

    // OC-5149 boundary: the first non-ASCII scalars and a sweep across Latin-1 and Latin Extended kill the word. Red
    // if the ASCII test is widened to `< 0xA0`, `< 0x100` or any other cut above 0x7F. (U+0080...U+009F are control
    // characters; the matcher already treats a key that types only those as a word reset, not as input.)
    @Test func everyPrintableScalarFromU00A0ToU024FKillsTheWord() {
        for value in UInt32(0xA0)...UInt32(0x24F) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let h = harness()
            h.type(":ab")
            _ = h.down(0, String(scalar))
            #expect(h.matcher.holdsNoCharacters, "U+\(String(value, radix: 16))")
            _ = h.down(backspace)
            h.type(":ab")
            #expect(h.space() == .pass, "U+\(String(value, radix: 16)) revived the word")
        }
    }

    // OC-5149 boundary, sampled across the planes: 2-, 3- and 4-byte UTF-8 scalars all kill the word.
    @Test(arguments: [0x07FF, 0x0800, 0x20AC, 0xFFFD, 0x10000, 0x1F600, 0xE0001])
    func multiByteScalarsKillTheWord(value: Int) throws {
        let scalar = try #require(Unicode.Scalar(UInt32(value)))
        let h = harness()
        h.type(":ab")
        _ = h.down(0, String(scalar))
        #expect(h.matcher.holdsNoCharacters)
        h.type(":ab")
        #expect(h.space() == .pass)
    }

    // OC-5149 boundary, the other side: every printable ASCII character, including ~ (0x7E) and the space-adjacent
    // punctuation, is ordinary input. It keeps the word alive and a following trigger still matches after Backspaces
    // remove it. Red if the ASCII cut is lowered (`< 0x7E` kills `~`, `< 0x30` kills digits and letters) or the
    // non-ASCII branch is taken for ASCII.
    @Test func everyPrintableAsciiCharacterIsOrdinaryInputAndNeverKillsTheWord() throws {
        for value in UInt8(0x21)...UInt8(0x7E) {
            let ch = String(UnicodeScalar(value))
            let h = harness()
            h.type(":ab")
            _ = h.down(0, ch)
            #expect(!h.matcher.holdsNoCharacters, "U+00\(String(value, radix: 16)) emptied the word")
            _ = h.down(backspace)
            #expect(try #require(h.space().match, "after \(ch) and Backspace").typedText == ":ab")
        }
    }

    // Pins what the ASCII cut cannot reach: 0x7F (DEL) and U+0080...U+009F are control characters, so a key that types
    // one is a word reset (the existing "types no printable character" rule), never input to `append`. The word is
    // cleared, not killed, and the next `:ab` matches. (Mutations of the ASCII cut at 0x7F, 0x80 or 0xA0 are therefore
    // equivalent: UTF-8 lead bytes of every non-ASCII scalar are at least 0xC2.)
    @Test(arguments: ["\u{7F}", "\u{80}", "\u{85}", "\u{9F}"])
    func controlCharactersResetTheWordInsteadOfKillingIt(character: String) throws {
        let h = harness()
        h.type(":a")
        #expect(h.down(0, character) == .pass)
        #expect(h.matcher.holdsNoCharacters)
        h.type(":ab")
        #expect(try #require(h.space().match).triggerLength == 3)
    }

    // MARK: OC-5150 the next word after a boundary matches

    // OC-5150: given a dead word, when each boundary key ends it, then the next `:ab` matches with length 3, and the
    // boundary that ended the dead word was passed through, not swallowed. Red if a boundary does not clear the flag.
    @Test(arguments: [
        (TriggerKeys.space, " "), (TriggerKeys.tab, "\t"), (TriggerKeys.returnKey, "\r"), (TriggerKeys.keypadEnter, "\r"),
    ])
    func everyBoundaryKeyEndsTheDeadWordAndTheNextWordMatches(keyCode: UInt16, characters: String) throws {
        let h = harness()
        h.type(":ab")
        _ = h.down(0, thai)
        #expect(h.down(keyCode, characters) == .pass)
        h.type(":ab")
        let match = try #require(h.space().match)
        #expect(match.itemId == ab)
        #expect(match.typedText == ":ab")
        #expect(match.triggerLength == 3)
    }

    // OC-5150: the next word matches again and again; the kill does not leak across a second dead word.
    @Test func eachDeadWordIsIndependentOfTheOnesBeforeIt() throws {
        let h = harness()
        for round in 1...3 {
            h.type(":ab")
            _ = h.down(0, thai)
            #expect(h.space() == .pass, "round \(round) dead word")
            h.type(":ab")
            #expect(try #require(h.space().match, "round \(round) next word").triggerLength == 3)
        }
    }

    // OC-5150: every other way the word ends also revives matching. Each is a reset the matcher already had; none may
    // keep the dead flag. Red if `clearWord` stops clearing `isDead`.
    @Test func everyResetEndsTheDeadWordToo() throws {
        func deadHarness() -> MatcherHarness {
            let h = harness()
            h.type(":ab")
            _ = h.down(0, thai)
            return h
        }
        func nextWordMatches(_ h: MatcherHarness, _ what: String) throws {
            h.type(":ab")
            #expect(try #require(h.space().match, "\(what)").triggerLength == 3)
        }
        let escape = deadHarness(); _ = escape.down(53); try nextWordMatches(escape, "Esc")
        let arrow = deadHarness(); _ = arrow.down(123); try nextWordMatches(arrow, "left arrow")
        let command = deadHarness(); _ = command.down(0, "b", flags: [.command]); try nextWordMatches(command, "command chord")
        let shiftSpace = deadHarness()
        #expect(shiftSpace.space(flags: [.shift]) == .pass)
        try nextWordMatches(shiftSpace, "shift+space")
        let own = deadHarness()
        _ = own.matcher.process(KeyEvent(kind: .keyDown, keyCode: 0, characters: "x", isFlotsamEvent: true))
        try nextWordMatches(own, "Flotsam's own event")
        let idle = deadHarness()
        idle.clock.advance(6)
        try nextWordMatches(idle, "5 s idle")
        let signal = deadHarness()
        signal.resetSignal.request()
        try nextWordMatches(signal, "reset signal")
        let direct = deadHarness()
        direct.matcher.reset()
        try nextWordMatches(direct, "reset()")
    }

    // MARK: Side rules around the kill

    // A dead word in an excluded application is not logged as a TRG-POL-002 suppression either: the word never
    // reached a trigger. Red if the kill is skipped in an excluded app.
    @Test func aNonAsciiCharacterInAnExcludedAppKillsTheWordWithoutALoggedSuppression() {
        let h = harness(excluded: ["com.example.editor"])
        h.type(":ab")
        _ = h.down(0, thai)
        _ = h.down(backspace)
        #expect(h.space() == .pass)
        h.type(":ab")
        #expect(h.space() == .suppressed(.excludedApp))  // the next word is judged as before
    }

    // The word started in one app, the kill happened, and focus moved: nothing matches and nothing traps.
    @Test func aDeadWordThatSpansAFocusChangeStaysQuietAndTheNextWordMatches() throws {
        let h = harness()
        h.type(":ab")
        _ = h.down(0, thai)
        h.environment.frontmost = FrontmostApp(bundleId: "com.example.other", processId: 300)
        #expect(h.space() == .pass)
        h.type(":ab")
        #expect(try #require(h.space().match).triggerLength == 3)
    }

    // Unchanged ASCII behaviour, a small differential: ASCII Backspace still edits the word, and an ASCII word of
    // any case still matches (the ASCII path must not have been routed through the kill).
    @Test func asciiBackspaceEditingAndCaseFoldingAreUnchanged() throws {
        let h = harness()
        h.type(":axx")
        _ = h.down(backspace)
        _ = h.down(backspace)
        h.type("b")
        #expect(try #require(h.space().match).typedText == ":ab")
        h.type(":Ab")
        #expect(h.space().match?.itemId == ab)
        // empty-buffer Backspace still kills an ASCII word (FR-005-11), unchanged by TASK-493
        _ = h.down(backspace)
        h.type(":ab")
        #expect(h.space() == .pass)
    }
}
