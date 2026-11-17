import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// Independent QA cases for the word buffer and matcher (FR-005-11, FR-005-12; OC-5076 to OC-5087). Written blind to the
/// implementer's tests: they probe boundaries and sequences those tests step around. Every expected value is a literal.
@Suite struct TriggerMatcherAdversarialTests {
    private let sig = UUID()
    private let other = UUID()

    private func harness() -> MatcherHarness { MatcherHarness(triggers: [sig: ";sig"]) }

    // MARK: Idle timeout boundary (OC-5076)

    @Test func theIdleTimeoutIsDecidedBetweenFourPointNineNineNineAndFivePointZeroZeroOneSeconds() {
        // given ";sig" typed, when the pause before Space is 4.999 s, then it expands; at 5.001 s it does not.
        let justInside = harness()
        justInside.type(";sig")
        justInside.clock.advance(4.999)
        #expect(justInside.space().match?.itemId == sig)

        let justOutside = harness()
        justOutside.type(";sig")
        justOutside.clock.advance(5.001)
        #expect(justOutside.space() == .pass)
    }

    @Test func aKeyUpAloneKeepsTheWordAliveAcrossALongTypingPause() {
        // given ";sig" typed with a 4 s gap before each key, when the total elapsed passes 5 s but no single gap does,
        // then the word still matches: the timeout is per gap, not per word.
        let h = harness()
        for ch in ";sig" {
            h.clock.advance(4)
            h.type(String(ch))
        }
        h.clock.advance(4)
        #expect(h.space().match?.itemId == sig)
    }

    @Test func aWordThatTimedOutDoesNotPoisonTheNextOne() {
        // given a word abandoned past the timeout, when ";sig" is typed afterwards, then it expands.
        let h = harness()
        h.type(";si")
        h.clock.advance(6)
        h.type("x")
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    // MARK: Reset signal (OC-5083, OC-5125)

    @Test func aResetRequestIsConsumedOnceAndDoesNotClearLaterWords() {
        // given one reset request, when it lands mid-word and a fresh ";sig" is typed afterwards, then the first word
        // is lost and the second expands: the signal is not sticky.
        let h = harness()
        h.type(";si")
        h.resetSignal.request()
        h.type("g")
        #expect(h.space() == .pass)

        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    @Test func manyResetRequestsBeforeOneEventClearOnlyThatOneEvent() {
        // given 50 requests queued before the next event, when ";sig" is typed afterwards, then it expands.
        let h = harness()
        for _ in 0..<50 { h.resetSignal.request() }
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    @Test func aResetRequestedBeforeTheBoundaryKeyStopsTheMatch() {
        // given ";sig" typed, when a reset arrives and the next event is the Space itself, then it does not expand.
        let h = harness()
        h.type(";sig")
        h.resetSignal.request()
        #expect(h.space() == .pass)
    }

    @Test func aResetClearsADeadWordSoTheNextWordIsLive() {
        // given a dead word (backspace on an empty buffer), when a reset arrives, then ";sig" expands without needing
        // a boundary key first.
        let h = harness()
        _ = h.down(TriggerKeys.backspace)
        h.resetSignal.request()
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    // MARK: FR-005-11: frontmost application change (OC-5083)

    @Test func aWordStartedInOneApplicationDoesNotExpandInTheNext() {
        // given ";sig" typed in the editor, when the frontmost app becomes another app and Space is pressed, then no
        // expansion happens: a change of frontmost application clears the buffer (FR-005-11, OC-5083).
        let h = harness()
        h.type(";sig")
        h.environment.frontmost = FrontmostApp(bundleId: "com.example.notes", processId: 200)

        withKnownIssue("DEFECT: no frontmost-application-change reset exists in the engine or matcher (FR-005-11)") {
            #expect(h.space() == .pass)
        }
    }

    @Test func theSameApplicationStayingFrontmostDoesNotResetTheWord() {
        // The control for the test above: nothing changed, so the word is still live and expands.
        let h = harness()
        h.type(";sig")
        h.environment.frontmost = FrontmostApp(bundleId: "com.example.editor", processId: 100)
        #expect(h.space().match?.itemId == sig)
    }

    // MARK: Dead words (OC-5078, OC-5079)

    @Test func backspacingPastTheStartOfTheWordKillsItEvenAfterTypingMore() {
        // given "ab" then three Backspaces (one past the start), when ";sig" Space is typed, then it does not expand;
        // when ";sig" Space is typed again, it does (OC-5078).
        let h = harness()
        h.type("ab")
        for _ in 0..<3 { _ = h.down(TriggerKeys.backspace) }
        h.type(";sig")
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    @Test func twentySixLettersThenBackspacingBackToFourStaysDead() {
        // given ";sig" plus 22 more letters (26 in all, past the 24 limit), when 22 Backspaces return to ";sig", then
        // Space does not expand (OC-5079).
        let h = harness()
        h.type(";sig" + String(repeating: "x", count: 22))
        for _ in 0..<22 { _ = h.down(TriggerKeys.backspace) }
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    @Test func aTwentyFifthCharacterKillsTheWordButAMatchAtTwentyFourStillWorks() {
        // given a 24-character trigger, when it is typed exactly, then it matches; typed with one extra character,
        // then it does not, and Space leaves the word clear for the next.
        let longTrigger = ";" + String(repeating: "a", count: 23)
        #expect(longTrigger.count == 24)
        let h = MatcherHarness(triggers: [other: longTrigger])
        h.type(longTrigger)
        #expect(h.space().match?.itemId == other)

        h.type(longTrigger + "a")
        #expect(h.space() == .pass)
        h.type(longTrigger)
        #expect(h.space().match?.itemId == other)
    }

    // MARK: Auto-repeat and layouts (OC-5081, OC-5082)

    @Test func autoRepeatedLettersAppendLikeOrdinaryKeys() {
        // given trigger ";zzzz", when ";" then "z" with three auto-repeat events (four z in all) then Space, then it
        // expands; with only two z it does not (OC-5082).
        let zs = MatcherHarness(triggers: [other: ";zzzz"])
        zs.type(";")
        _ = zs.down(0, "z")
        for _ in 0..<3 { _ = zs.down(0, "z", repeat: true) }
        #expect(zs.space().match?.itemId == other)

        let tooFew = MatcherHarness(triggers: [other: ";zzzz"])
        tooFew.type(";")
        _ = tooFew.down(0, "z")
        _ = tooFew.down(0, "z", repeat: true)
        #expect(tooFew.space() == .pass)
    }

    @Test func aLayoutThatTypesTheTriggerFromOtherKeyCodesStillMatches() {
        // given keys whose key codes are unrelated to the letters (a non-QWERTY layout), when they produce ";sig",
        // then the match uses the characters, not the key codes (OC-5081).
        let h = harness()
        for (code, ch) in [(41, ";"), (1, "s"), (34, "i"), (5, "g")] as [(UInt16, String)] {
            _ = h.down(code, ch)
            _ = h.up(code)
        }
        #expect(h.space().match?.itemId == sig)
    }

    @Test func aMultiCharacterKeyEventCountsEveryCharacterTowardTheLimit() {
        // given one event carrying 25 characters (a paste-like or IME burst), when Space follows, then the word is dead
        // and nothing matches, even though only one key down arrived.
        let h = harness()
        _ = h.down(0, String(repeating: "a", count: 25))
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    // MARK: Boundary keys (OC-5085, OC-5086)

    @Test(arguments: [
        (TriggerKeys.space, "space"), (TriggerKeys.tab, "tab"),
        (TriggerKeys.returnKey, "return"), (TriggerKeys.keypadEnter, "keypad enter"),
    ])
    func everyBoundaryKeyMatchesAndIsRecordedAsTheOneThatEndedTheWord(key: UInt16, name: String) throws {
        // given ";sig", when it is ended with each boundary key, then it matches and the match carries that key code.
        let h = harness()
        h.type(";sig")
        let match = try #require(h.down(key, " ").match, "\(name)")
        #expect(match.boundaryKeyCode == key)
        #expect(match.itemId == sig)
    }

    @Test(arguments: [KeyEventFlags.option, .command, .control, .shift])
    func aModifiedBoundaryKeyPassesAndEndsTheWordWithoutAMatch(flag: KeyEventFlags) {
        // given ";sig" typed, when the boundary key carries ⌥, ⌘, ⌃ or ⇧, then it passes and the word is gone.
        let h = harness()
        h.type(";sig")
        #expect(h.down(TriggerKeys.space, " ", flags: flag) == .pass)
        #expect(h.space() == .pass)
    }

    @Test func aSecondBoundaryKeyPressedWhileTheFirstIsHeldIsAFreshPress() {
        // given a match on Space whose key-up is still pending, when ";sig" is typed again and Space arrives as a new
        // (non-repeat) press, then it matches again instead of being swallowed as an auto-repeat.
        let h = harness()
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
        // No key-up for the first Space: the system lost it.
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    @Test func autoRepeatsOfAHeldBoundaryAreSwallowedOnlyForTheKeyThatMatched() {
        // given a match on Space, when a repeat of Tab arrives (a different key) with no word, then it passes.
        let h = harness()
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
        #expect(h.down(TriggerKeys.space, " ", repeat: true) == .consume)
        #expect(h.down(TriggerKeys.tab, "\t", repeat: true) == .pass)
    }

    // MARK: Matching (FR-005-12)

    @Test func aTriggerEmbeddedAfterOtherCharactersNeverExpands() {
        // given trigger ";sig", when "foo;sig" and "x;sig" Space are typed, then neither expands (business rule: a
        // match needs a word that begins at a word start).
        let h = harness()
        h.type("foo;sig")
        #expect(h.space() == .pass)
        h.type("x;sig")
        #expect(h.space() == .pass)
        h.type(";sigx")
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    @Test func aTriggerRemovedMidWordNoLongerExpandsAndOneAddedMidWordDoes() {
        // given ";sig" typed, when the item is deleted before Space, then no expansion (FR-005-22: gone immediately);
        // given a new trigger installed mid-word, then it expands at the boundary.
        let h = harness()
        h.type(";sig")
        h.store.remove(itemIds: [sig])
        #expect(h.space() == .pass)

        h.type(";new")
        h.install([other: ";new"])
        #expect(h.space().match?.itemId == other)
    }

    @Test func typedTextKeepsTheCaseTheUserTypedWhileMatchingIgnoresIt() throws {
        // given ";SiG" typed, when Space ends it, then the match is for the item and typedText is ";SiG" (the
        // expander re-posts exactly what was typed on failure).
        let h = harness()
        h.type(";SiG")
        let match = try #require(h.space().match)
        #expect(match.typedText == ";SiG")
        #expect(match.triggerLength == 4)
    }

    @Test func aWordMadeOfSeveralKeysThatCombineIntoOneCharacterReportsItsCharacterLength() throws {
        // given the trigger ";ab" typed with a dead-key style sequence that ends in a combining mark, when Space ends
        // the word, then the typed text and length agree with each other (graphemes), so the backspace count matches
        // what the user sees.
        let h = MatcherHarness(triggers: [other: ";ab"])
        h.type(";ab")
        let match = try #require(h.space().match)
        #expect(match.triggerLength == match.typedText.count)
        #expect(match.triggerLength == 3)

        let combining = MatcherHarness(triggers: [other: ";ab"])
        combining.type(";a")
        combining.type("b\u{0301}")  // "b" then an acute accent in its own event
        #expect(combining.space() == .pass, "b with an accent is not the trigger ;ab")
    }

    // MARK: Non-text input (OC-5077)

    @Test func arrowThenSpaceAndCommandChordThenSpaceBothCancelTheWord() {
        // given ";sig" followed by ← then →, and separately ";sig" then ⌘B, when Space follows, then neither expands.
        let arrows = harness()
        arrows.type(";sig")
        _ = arrows.down(123)
        _ = arrows.down(124)
        #expect(arrows.space() == .pass)

        let chord = harness()
        chord.type(";sig")
        _ = chord.down(11, "b", flags: .command)
        #expect(chord.space() == .pass)
    }

    @Test func aFunctionKeyWithPrivateUseCharactersClearsTheWord() {
        // given ";sig" and a key whose characters are the macOS private-use arrow scalar, when Space follows, then no
        // expansion; a key with an empty character string likewise.
        let privateUse = harness()
        privateUse.type(";sig")
        _ = privateUse.down(0, "\u{F700}")
        #expect(privateUse.space() == .pass)

        let empty = harness()
        empty.type(";sig")
        _ = empty.down(0, "")
        #expect(empty.space() == .pass)
    }

    @Test func aTabInTheMiddleOfAWordEndsItAndTheTextAfterTheTabStartsFresh() {
        // given ";si" Tab "g" Space, when the Tab is a non-matching boundary, then no expansion; ";sig" Space still works.
        let h = harness()
        h.type(";si")
        #expect(h.down(TriggerKeys.tab, "\t") == .pass)
        h.type("g")
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }
}
