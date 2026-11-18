import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// TASK-492 (FR-005-11, FR-005-14): the word buffer's length is the grapheme count of the buffer itself. A combining
/// mark that arrives as its own key event joins the previous character, so it must not count as another one, and
/// Backspace on an empty buffer must never trap on the tap thread.
@Suite struct Task492BufferLengthTests {
    private let sig = UUID()
    private let thai = "\u{0E01}"  // KO KAI
    private let thaiMark = "\u{0E31}"  // MAI HAN-AKAT, a combining mark
    private let acute = "\u{0301}"

    private func harness(_ trigger: String = ";sig") -> MatcherHarness { MatcherHarness(triggers: [sig: trigger]) }

    // Bug report W485-F1: base, then its combining mark as a separate event, then Backspace twice trapped.
    @Test func thaiBasePlusSeparateMarkThenTwoBackspacesDoesNotTrap() {
        let h = harness()
        _ = h.down(0, thai)
        _ = h.down(0, thaiMark)
        #expect(h.down(TriggerKeys.backspace) == .pass)
        #expect(h.down(TriggerKeys.backspace) == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    // The second Backspace emptied the word, so the word is dead until the next boundary; the boundary revives it.
    @Test func backspaceOnAnEmptiedWordKillsItAndTheNextBoundaryRevivesIt() throws {
        let h = harness()
        _ = h.down(0, thai)
        _ = h.down(0, thaiMark)
        _ = h.down(TriggerKeys.backspace)
        _ = h.down(TriggerKeys.backspace)
        h.type(";sig")
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(try #require(h.space().match).triggerLength == 4)
    }

    // N Backspaces after multi-codepoint input, whether the scalars arrive in one event or several, never trap, and
    // each Backspace removes one grapheme.
    @Test(arguments: [
        ["e\u{0301}"],  // one event, two scalars
        ["e", "\u{0301}"],  // two events, one grapheme
        ["\u{0E01}", "\u{0E31}", "\u{0E49}"],  // base plus two marks, three events
        ["\u{1F1FA}\u{1F1F8}"],  // flag: two regional indicators, one grapheme
        ["\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"],  // ZWJ family: five scalars, one grapheme
    ])
    func manyBackspacesAfterMultiCodepointInputNeverTrap(events: [String]) {
        let h = harness()
        for text in events { _ = h.down(0, text) }
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.down(TriggerKeys.backspace)
        #expect(h.matcher.holdsNoCharacters)
        for _ in 0..<5 { #expect(h.down(TriggerKeys.backspace) == .pass) }
        #expect(h.matcher.holdsNoCharacters)
    }

    // One Backspace removes the whole cluster built from a character and a later mark.
    @Test func aMarkJoinsTheLastCharacterSoOneBackspaceRemovesBoth() throws {
        let h = harness()
        h.type(";sig")
        _ = h.down(0, acute)
        _ = h.down(TriggerKeys.backspace)
        h.type("g")
        #expect(try #require(h.space().match).typedText == ";sig")
    }

    // FR-005-14 step 5: the Backspace count is the typed trigger's length in characters. A match is always ASCII (the
    // grammar is), so it has no combining sequence and its count equals the keys typed; a word that carried a mark
    // never equals a trigger.
    @Test func triggerLengthIsTheTypedLengthAfterAMarkWasBackspacedAway() throws {
        let h = harness()
        h.type(";sig")
        _ = h.down(0, acute)
        _ = h.down(TriggerKeys.backspace)
        h.type("g")
        let match = try #require(h.space().match)
        #expect(match.triggerLength == 4)
        #expect(match.triggerLength == match.typedText.count)
    }

    @Test func aWordCarryingACombiningMarkNeverMatches() {
        let h = harness()
        h.type(";sig")
        _ = h.down(0, acute)
        #expect(h.space() == .pass)
    }

    // The cap counts graphemes of the buffer, not characters delivered: marks do not push the word over 24.
    @Test func manyCombiningMarksDoNotTripTheCap() throws {
        let h = harness()
        h.type(";sig")
        for _ in 0..<30 { _ = h.down(0, acute) }
        _ = h.down(TriggerKeys.backspace)  // removes the one cluster "g" plus its marks
        h.type("g")
        let match = try #require(h.space().match)
        #expect(match.typedText == ";sig")
        #expect(match.triggerLength == 4)
    }

    @Test func aMarkOnA24CharacterWordKeepsItLiveAndTheTriggerLengthIs24() throws {
        let trigger = ";" + String(repeating: "a", count: TriggerGrammar.maximumLength - 1)
        let h = harness(trigger)
        h.type(trigger)
        _ = h.down(0, acute)  // still 24 graphemes
        _ = h.down(TriggerKeys.backspace)  // 23
        h.type("a")
        let match = try #require(h.space().match)
        #expect(match.triggerLength == TriggerGrammar.maximumLength)
        #expect(match.typedText == trigger)
    }

    // A 25th grapheme kills the word, and Backspace does not bring it back before the next boundary.
    @Test func the25thGraphemeKillsTheWordAndBackspaceDoesNotRevive() {
        let trigger = ";" + String(repeating: "a", count: TriggerGrammar.maximumLength - 1)
        let h = harness(trigger)
        h.type(trigger + "a")
        #expect(h.matcher.holdsNoCharacters)
        _ = h.down(TriggerKeys.backspace)
        #expect(h.space() == .pass)
        h.type(trigger)
        #expect(h.space().match != nil)
    }

    // A multi-scalar event that would push the word past the cap kills it even though it is one event.
    @Test func aSingleEventOfSeveralGraphemesOverTheCapKillsTheWord() {
        let h = harness()
        h.type(String(repeating: "x", count: TriggerGrammar.maximumLength - 1))
        _ = h.down(0, "yz")
        #expect(h.matcher.holdsNoCharacters)
    }
}
