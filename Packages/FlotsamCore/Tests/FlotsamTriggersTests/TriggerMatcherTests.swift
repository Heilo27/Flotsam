import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// FR-005-11, FR-005-12, FR-005-13 / AC-005-10, AC-005-11 and the suppression ACs.
@Suite struct TriggerMatcherTests {
    private let sig = UUID()
    private let short = UUID()

    private func harness() -> MatcherHarness { MatcherHarness(triggers: [sig: ";sig", short: ";s"]) }

    // MARK: Matching and boundary keys (FR-005-12)

    @Test func aWholeWordEqualToATriggerMatchesAtTheBoundaryAndSwallowsTheKey() throws {
        let h = harness()
        h.type(";sig")
        let result = h.space()
        let match = try #require(result.match)
        #expect(match.itemId == sig)
        #expect(match.typedText == ";sig")
        #expect(match.triggerLength == 4)
        #expect(match.boundaryKeyCode == TriggerKeys.space)
        #expect(match.app == FrontmostApp(bundleId: "com.example.editor", processId: 100))
        #expect(result.decision == .consume)
    }

    @Test func theMatchingKeyUpIsSwallowedOnceAndLaterKeyUpsPass() {
        let h = harness()
        h.type(";sig")
        _ = h.space()
        #expect(h.up(TriggerKeys.space) == .consume)
        #expect(h.up(TriggerKeys.space) == .pass)
    }

    @Test func holdingTheBoundaryKeyConsumesItsAutoRepeatsUntilReleased() {
        let h = harness()
        h.type(";sig")
        _ = h.space()
        #expect(h.down(TriggerKeys.space, " ", repeat: true) == .consume)
        #expect(h.down(TriggerKeys.space, " ", repeat: true) == .consume)
        #expect(h.up(TriggerKeys.space) == .consume)
        #expect(h.down(TriggerKeys.space, " ", repeat: true) == .pass)
    }

    @Test func comparisonIsCaseInsensitive() {
        let h = harness()
        h.type(";SiG")
        #expect(h.space().match?.itemId == sig)
    }

    @Test func aPrefixTriggerNeverFiresEarlyAndEachFiresOnItsOwnWord() {
        let h = harness()
        h.type(";s")
        #expect(h.space().match?.itemId == short)
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    @Test func theTypedWordMustEqualTheTriggerNotMerelyEndWithIt() {
        let h = harness()
        h.type("hello;sig")
        #expect(h.space() == .pass)
        h.type(";signature")
        #expect(h.space() == .pass)
    }

    @Test(arguments: [
        (TriggerKeys.tab, "\t"), (TriggerKeys.returnKey, "\r"), (TriggerKeys.keypadEnter, "\r"), (TriggerKeys.space, " "),
    ])
    func everyBoundaryKeyMatches(keyCode: UInt16, characters: String) {
        let h = harness()
        h.type(";sig")
        #expect(h.down(keyCode, characters).match?.boundaryKeyCode == keyCode)
    }

    @Test func aNonMatchingBoundaryPassesAndClearsTheWord() {
        let h = harness()
        h.type("nope")
        #expect(h.space() == .pass)
        #expect(h.up(TriggerKeys.space) == .pass)
        h.type(";sig")
        #expect(h.space().match != nil)
    }

    @Test func shiftedBoundaryEndsTheWordWithoutAMatch() {
        let h = harness()
        h.type(";sig")
        #expect(h.space(flags: .shift) == .pass)
        #expect(h.space() == .pass)
    }

    @Test func capsLockAndShiftStillCountAsTyping() {
        let h = harness()
        h.type(";SIG", flags: [.shift, .capsLock])
        #expect(h.space(flags: .capsLock).match?.itemId == sig)
    }

    @Test func anEmptyOrOneCharacterWordNeverMatches() {
        let h = harness()
        #expect(h.space() == .pass)
        h.type(";")
        #expect(h.space() == .pass)
    }

    @Test func aTriggerCollisionInTheSnapshotMatchesNothing() {
        let h = MatcherHarness(triggers: [UUID(): ";dup", UUID(): ";DUP", sig: ";sig"])
        h.type(";dup")
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    // MARK: Buffer rules (FR-005-11)

    @Test func backspaceRemovesTheLastCharacter() {
        let h = harness()
        h.type(";sigx")
        _ = h.down(TriggerKeys.backspace)
        #expect(h.space().match?.itemId == sig)
    }

    @Test func backspaceOnAnEmptyBufferKillsTheWordUntilTheNextBoundary() {
        let h = harness()
        _ = h.down(TriggerKeys.backspace)
        h.type(";sig")
        #expect(h.space() == .pass, "dead word")
        h.type(";sig")
        #expect(h.space().match != nil, "boundary revived it")
    }

    @Test func aWordPastTwentyFourCharactersIsDeadEvenIfBackspacedBackIntoRange() {
        let h = harness()
        h.type(String(repeating: "a", count: 25))
        for _ in 0..<22 { _ = h.down(TriggerKeys.backspace) }
        h.type(";sig")
        #expect(h.space() == .pass)
    }

    @Test func aWordOfExactlyTwentyFourCharactersCanStillMatch() {
        let long = ";" + String(repeating: "a", count: 23)
        let h = MatcherHarness(triggers: [sig: long])
        h.type(long)
        #expect(h.space().match?.itemId == sig)
    }

    @Test(arguments: [53, 123, 124, 125, 126, 115, 119, 116, 121, 122, 105])
    func resetKeysClearTheWord(keyCode: UInt16) {
        let h = harness()
        h.type(";si")
        _ = h.down(keyCode)
        h.type("g")
        #expect(h.space() == .pass)
    }

    @Test func aKeyThatTypesNothingPrintableClearsTheWord() {
        let h = harness()
        h.type(";si")
        _ = h.down(200, "\u{F704}")
        h.type("g")
        #expect(h.space() == .pass)
    }

    @Test(arguments: [KeyEventFlags.command, .control, .option])
    func aCommandChordClearsTheWord(flags: KeyEventFlags) {
        let h = harness()
        h.type(";si")
        _ = h.down(5, "g", flags: flags)
        h.type("g")
        #expect(h.space() == .pass)
    }

    @Test func aMouseDownClearsTheWord() {
        let h = harness()
        h.type(";si")
        _ = h.matcher.process(KeyEvent(kind: .mouseDown))
        h.type("g")
        #expect(h.space() == .pass)
    }

    @Test func fiveSecondsWithoutAKeyEventClearsTheWord() {
        let h = harness()
        h.type(";si")
        h.clock.advance(5.5)
        h.type("g")
        #expect(h.space() == .pass)

        h.type(";si")
        h.clock.advance(4.5)
        h.type("g")
        #expect(h.space().match?.itemId == sig)
    }

    @Test func aResetRequestedFromAnotherThreadClearsTheWordAtTheNextEvent() {
        let h = harness()
        h.type(";si")
        h.resetSignal.request()
        h.type("g")
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space().match != nil, "the request is consumed once")
    }

    @Test func flotsamsOwnEventsAreIgnoredAndClearTheWord() {
        let h = harness()
        h.type(";si")
        let own = h.matcher.process(KeyEvent(kind: .keyDown, keyCode: 0, characters: "x", isFlotsamEvent: true))
        #expect(own == .pass)
        h.type("g")
        #expect(h.space() == .pass)
    }

    @Test func flotsamsOwnBoundaryKeyNeverMatches() {
        let h = harness()
        h.type(";sig")
        let own = h.matcher.process(KeyEvent(kind: .keyDown, keyCode: TriggerKeys.space, characters: " ", isFlotsamEvent: true))
        #expect(own == .pass)
    }

    // MARK: Suppression (FR-005-13)

    @Test func secureEventInputSuppressesAndPassesTheKey() {
        let h = harness()
        h.environment.secureInput = true
        h.type(";sig")
        let result = h.space()
        #expect(result == .suppressed(.secureInput))
        #expect(result.decision == .pass)
        #expect(h.up(TriggerKeys.space) == .pass)
    }

    @Test func anExcludedApplicationSuppresses() {
        let h = MatcherHarness(triggers: [sig: ";sig"], excluded: ["com.apple.Terminal"])
        h.environment.frontmost = FrontmostApp(bundleId: "com.apple.Terminal", processId: 5)
        h.type(";sig")
        #expect(h.space() == .suppressed(.excludedApp))
    }

    @Test func theExclusionListIsReadLiveAtEachMatch() {
        let h = harness()
        h.type(";sig")
        #expect(h.space().match != nil)
        h.store.setExcludedApps(["com.example.editor"])
        h.type(";sig")
        #expect(h.space() == .suppressed(.excludedApp))
    }

    @Test func flotsamsOwnWindowsAreAlwaysExcluded() {
        let h = harness()
        h.environment.frontmost = FrontmostApp(bundleId: MatcherHarness.ownBundleId, processId: 1)
        h.type(";sig")
        #expect(h.space() == .suppressed(.excludedApp))
    }

    @Test func anInputMethodSuppresses() {
        let h = harness()
        h.environment.inputMethodActive = true
        h.type(";sig")
        #expect(h.space() == .suppressed(.inputMethod))
    }

    @Test func anUnknownFrontmostApplicationSuppresses() {
        let h = harness()
        h.environment.frontmost = nil
        h.type(";sig")
        #expect(h.space() == .suppressed(.unknownApp))
        h.environment.frontmost = FrontmostApp(bundleId: nil, processId: 9)
        h.type(";sig")
        #expect(h.space() == .suppressed(.unknownApp))
    }

    @Test func suppressionClearsTheWordSoTheNextAttemptStartsFresh() {
        let h = harness()
        h.environment.secureInput = true
        h.type(";sig")
        _ = h.space()
        h.environment.secureInput = false
        h.type(";sig")
        #expect(h.space().match != nil)
    }

    @Test func theEnvironmentIsNeverAskedUnlessAWordMatched() {
        let h = harness()
        h.type("hello world;si")
        _ = h.space()
        _ = h.down(TriggerKeys.backspace)
        _ = h.down(53)
        #expect(h.environment.callCount == 0)
        h.type(";sig")
        _ = h.space()
        #expect(h.environment.callCount > 0)
    }
}
