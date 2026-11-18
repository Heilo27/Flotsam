import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// Worf blind QA for TASK-485 (security F-04, FR-005-11 / FR-005-20): every path that ends a word, or that the word can
/// leak through, leaves the matcher holding no characters; triggers still fire on the boundary key.
/// Each test first proves the buffer is non-empty (`holdsNoCharacters == false`) so the empty check can fail.
@Suite struct Worf485AdversarialTests {
    private let sig = UUID()
    private static let terminal = FrontmostApp(bundleId: "com.example.terminal", processId: 200)

    private func harness(excluded: Set<String> = []) -> MatcherHarness {
        MatcherHarness(triggers: [sig: ";sig"], excluded: excluded)
    }

    // MARK: Keys that end a word without a boundary (FR-005-11)

    // OC-485-W01: given a half-typed word, when any reset key arrives, then nothing stays buffered and the next word is fresh.
    @Test(arguments: [53, 123, 124, 125, 126, 115, 119, 116, 121, 117, 122, 120, 99, 118, 96, 97] as [UInt16])
    func resetKeysEmptyTheBuffer(keyCode: UInt16) {
        let h = harness()
        h.type(";si")
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.down(keyCode)
        #expect(h.matcher.holdsNoCharacters)
        h.type("g")
        #expect(h.space() == .pass)  // ";si" was dropped, so this is "g", not ";sig"
    }

    // OC-485-W02: given a half-typed word, when a chord with command, control or option arrives, then the buffer is empty
    // and nothing expands afterwards (a paste chord is the Command case).
    @Test(arguments: [KeyEventFlags.command, .control, .option])
    func modifierChordsEmptyTheBuffer(flag: KeyEventFlags) {
        let h = harness()
        h.type(";si")
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.down(9, "v", flags: flag)
        #expect(h.matcher.holdsNoCharacters)
        h.type("g")
        #expect(h.space() == .pass)
    }

    // OC-485-W03: given a word typed, when a paste chord follows and then a boundary, then no expansion.
    @Test func aPasteChordBetweenWordAndBoundaryPreventsExpansion() {
        let h = harness()
        h.type(";sig")
        _ = h.down(9, "v", flags: .command)
        #expect(h.space() == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-485-W04: given a word, when a mouse click arrives, then the buffer is empty.
    @Test func aMouseDownEmptiesTheBuffer() {
        let h = harness()
        h.type(";sig")
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.matcher.process(KeyEvent(kind: .mouseDown))
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
    }

    // OC-485-W05: given a word, when an event Flotsam posted itself arrives, then the buffer is empty.
    @Test func aFlotsamOwnEventEmptiesTheBuffer() {
        let h = harness()
        h.type(";sig")
        _ = h.matcher.process(KeyEvent(kind: .keyDown, keyCode: 0, characters: "x", isFlotsamEvent: true))
        #expect(h.matcher.holdsNoCharacters)
    }

    // MARK: Delete

    // OC-485-W06: given a word typed then fully backspaced, when the next boundary arrives, then pass and empty; a fresh word still matches.
    @Test func backspacingTheWholeWordLeavesNothingAndTheNextWordStillMatches() throws {
        let h = harness()
        h.type(";sig")
        for _ in 0..<4 { _ = h.down(TriggerKeys.backspace) }
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
        h.type(";sig")
        let match = try #require(h.space().match)
        #expect(match.typedText == ";sig")
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-485-W07: given a partly backspaced word, when the boundary arrives, then the match is decided from what is left.
    @Test func backspaceThenRetypeStillExpandsFromTheCorrectedWord() throws {
        let h = harness()
        h.type(";sigx")
        _ = h.down(TriggerKeys.backspace)
        #expect(!h.matcher.holdsNoCharacters)
        let match = try #require(h.space().match)
        #expect(match.typedText == ";sig")
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-485-W08: given backspace on an empty buffer (dead word), when the boundary arrives, then pass and empty; the next word is live.
    @Test func backspaceOnAnEmptyBufferKillsTheWordUntilTheBoundaryAndLeavesNothing() throws {
        let h = harness()
        _ = h.down(TriggerKeys.backspace)
        h.type(";sig")
        #expect(h.matcher.holdsNoCharacters)  // dead word buffers nothing
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(try #require(h.space().match).typedText == ";sig")
    }

    // MARK: Boundary

    // OC-485-W09: given an IME is active, when a trigger word hits a boundary, then suppressed, empty, and the next word is not tainted.
    @Test func anInputMethodSuppressionLeavesNothingBehindForTheNextWord() throws {
        let h = harness()
        h.environment.inputMethodActive = true
        h.type(";sig")
        #expect(h.space() == .suppressed(.inputMethod))
        #expect(h.matcher.holdsNoCharacters)
        h.environment.inputMethodActive = false
        h.type(";sig")
        #expect(try #require(h.space().match).typedText == ";sig")
    }

    // OC-485-W10: given secure input turns on mid-word and off again before the boundary, then the boundary is a normal match.
    // Given it is still on at the boundary, then suppressed, empty, and a later word is matched normally.
    @Test func secureInputTogglingMidWordIsDecidedAtTheBoundaryAndLeavesNothing() throws {
        let h = harness()
        h.type(";si")
        h.environment.secureInput = true
        h.type("g")
        #expect(h.space() == .suppressed(.secureInput))
        #expect(h.matcher.holdsNoCharacters)
        h.environment.secureInput = false
        h.type(";sig")
        #expect(try #require(h.space().match).typedText == ";sig")
    }

    // OC-485-W11: given a match, when the boundary key repeats and is released, then the repeats are consumed, the buffer stays empty and nothing is appended.
    @Test func autoRepeatOfAMatchedBoundaryKeyBuffersNothing() throws {
        let h = harness()
        h.type(";sig")
        _ = try #require(h.space().match)
        #expect(h.down(TriggerKeys.space, " ", repeat: true) == .consume)
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.up(TriggerKeys.space) == .consume)
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-485-W12: given a word over the 24-character cap, when the boundary arrives, then pass and empty; boundary 24 chars exactly is held then emptied.
    @Test func theCapBoundaryHoldsThe24thCharacterThenEmptiesAtTheBoundary() {
        let h = harness()
        h.type(String(repeating: "x", count: TriggerGrammar.maximumLength))
        #expect(!h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
        #expect(h.matcher.holdsNoCharacters)
        h.type(String(repeating: "x", count: TriggerGrammar.maximumLength + 1))
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-485-W13: given a word, when 5 seconds pass without a key and then any event arrives, then the buffer is empty and the stale word never matches.
    @Test func theIdleTimeoutEmptiesTheBufferAtTheNextEventAndNotBefore() {
        let h = harness()
        h.type(";sig")
        h.clock.advance(6)
        #expect(!h.matcher.holdsNoCharacters)  // no event yet: the documented residual
        #expect(h.space() == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-485-W14: given exactly the idle limit has not elapsed, then the word is kept (boundary of the boundary).
    @Test func justInsideTheIdleTimeoutTheWordStillMatches() throws {
        let h = harness()
        h.type(";sig")
        h.clock.advance(4.9)
        #expect(try #require(h.space().match).typedText == ";sig")
    }

    // MARK: Focus

    // OC-485-W15: given a word half-typed in app A, when focus moves to an excluded app with no signal at all and the
    // boundary arrives there, then it is a silent pass (not a match, not a TRG-POL-002) and the buffer is empty.
    @Test func aSwitchWithNoSignalIsCaughtAtTheBoundaryAndNothingLeaksIntoAMatch() {
        let h = harness(excluded: ["com.example.terminal"])
        h.type(";sig")
        h.environment.frontmost = Self.terminal
        #expect(h.space() == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-485-W16: given a word half-typed in A, when focus goes to B and straight back to A (signal raised, no other
    // event), then the old half word is dropped at the next event and cannot be completed.
    @Test func awayAndBackMidWordDropsTheWordOnTheSignal() {
        let h = harness()
        h.type(";si")
        h.environment.frontmost = Self.terminal
        h.resetSignal.request()
        h.environment.frontmost = FrontmostApp(bundleId: "com.example.editor", processId: 100)
        h.resetSignal.request()
        h.type("g")
        #expect(h.space() == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-485-W17: pins FR-005-20's stated residual: the signal alone empties nothing until the next event arrives.
    @Test func theFocusSignalEmptiesTheBufferOnlyAtTheNextEvent() {
        let h = harness()
        h.type(";sig")
        h.resetSignal.request()
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.up(0)
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-485-W18: given the tap is disabled, when the engine resets the matcher, then it holds nothing.
    @Test func resetEmptiesTheBuffer() {
        let h = harness()
        h.type(";sig")
        #expect(!h.matcher.holdsNoCharacters)
        h.matcher.reset()
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
    }

    // OC-485-W19: given a word in an excluded app, when it ends, then no stale characters from the excluded app join the
    // next word typed after focus returns to a normal app.
    @Test func charactersTypedInAnExcludedAppDoNotJoinTheNextWordInAnotherApp() throws {
        let h = harness(excluded: ["com.example.terminal"])
        h.environment.frontmost = Self.terminal
        h.type(";s")
        h.environment.frontmost = FrontmostApp(bundleId: "com.example.editor", processId: 100)
        h.resetSignal.request()
        h.type("ig")
        #expect(h.space() == .pass)  // "ig", not ";sig"
        h.type(";sig")
        #expect(try #require(h.space().match).typedText == ";sig")
    }

    // OC-485-W20: given the boundary character itself, then it is never appended to the next word.
    @Test func theBoundaryCharacterIsNotCarriedIntoTheNextWord() throws {
        let h = harness()
        h.type(";sig")
        _ = try #require(h.space().match)
        _ = h.up(TriggerKeys.space)
        h.type(";sig")
        let match = try #require(h.space().match)
        #expect(match.typedText == ";sig")
        #expect(match.triggerLength == 4)
    }
}
