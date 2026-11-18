import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// Security F-04 (TASK-485), FR-005-11 / FR-005-20: no typed character stays in the word buffer after a boundary key,
/// whatever the outcome, nor after focus moves to an excluded application. Expansion is unaffected: the match is
/// still made from the word the boundary key ended.
@Suite struct Task485BufferClearTests {
    private let sig = UUID()
    private static let excludedApp = FrontmostApp(bundleId: "com.example.terminal", processId: 200)

    private func harness(excluded: Set<String> = []) -> MatcherHarness {
        MatcherHarness(triggers: [sig: ";sig"], excluded: excluded)
    }

    @Test func theBufferHoldsTheWordMidWordSoTheEmptyChecksAreNotVacuous() {
        let h = harness()
        #expect(h.matcher.holdsNoCharacters)
        h.type("abc")
        #expect(!h.matcher.holdsNoCharacters)
    }

    // MARK: Boundary

    @Test(arguments: [
        (TriggerKeys.space, " "), (TriggerKeys.tab, "\t"), (TriggerKeys.returnKey, "\r"), (TriggerKeys.keypadEnter, "\r"),
    ])
    func theBufferIsEmptyAfterANonMatchingBoundary(keyCode: UInt16, characters: String) {
        let h = harness()
        h.type("hunter2")
        #expect(h.down(keyCode, characters) == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    @Test(arguments: [
        (TriggerKeys.space, " "), (TriggerKeys.tab, "\t"), (TriggerKeys.returnKey, "\r"), (TriggerKeys.keypadEnter, "\r"),
    ])
    func aTriggerStillMatchesOnEveryBoundaryKeyAndTheBufferIsEmptyAfterwards(keyCode: UInt16, characters: String) throws {
        let h = harness()
        h.type(";sig")
        let match = try #require(h.down(keyCode, characters).match)
        #expect(match.itemId == sig)
        #expect(match.typedText == ";sig")
        #expect(match.triggerLength == 4)
        #expect(h.matcher.holdsNoCharacters)
    }

    @Test func theBufferIsEmptyAfterEverySuppressedMatch() {
        let secure = harness()
        secure.environment.secureInput = true
        secure.type(";sig")
        #expect(secure.space() == .suppressed(.secureInput))
        #expect(secure.matcher.holdsNoCharacters)

        let method = harness()
        method.environment.inputMethodActive = true
        method.type(";sig")
        #expect(method.space() == .suppressed(.inputMethod))
        #expect(method.matcher.holdsNoCharacters)

        let unknown = harness()
        unknown.environment.frontmost = nil
        unknown.type(";sig")
        #expect(unknown.space() == .suppressed(.unknownApp))
        #expect(unknown.matcher.holdsNoCharacters)

        let excluded = harness(excluded: ["com.example.editor"])
        excluded.type(";sig")
        #expect(excluded.space() == .suppressed(.excludedApp))
        #expect(excluded.matcher.holdsNoCharacters)
    }

    @Test func theBufferIsEmptyAfterAWordThatStartedInAnotherAppEndsAtABoundary() {
        let h = harness()
        h.type(";sig")
        h.environment.frontmost = FrontmostApp(bundleId: "com.example.other", processId: 300)
        #expect(h.space() == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    @Test func theBufferIsEmptyAfterABoundaryEndsADeadWord() {
        let h = harness()
        h.type(String(repeating: "x", count: TriggerGrammar.maximumLength + 1))
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    @Test func aShiftedBoundaryKeyEndsTheWordAndEmptiesTheBuffer() {
        let h = harness()
        h.type(";sig")
        #expect(h.space(flags: .shift) == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    @Test func nothingFromAFinishedWordCarriesIntoTheNextOne() {
        let h = harness()
        h.type("hello")
        _ = h.space()
        h.type("sig")  // would read ";sig" only if "hello" or its boundary had stayed
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space().match?.typedText == ";sig")
        #expect(h.matcher.holdsNoCharacters)
    }

    // MARK: Excluded-app focus

    @Test func theBufferIsEmptyOnceFocusMovesToAnExcludedApp() {
        let h = harness(excluded: ["com.example.terminal"])
        h.type("pass")
        #expect(!h.matcher.holdsNoCharacters)
        // What `TriggerEngine.frontmostApplicationDidChange()` does; the matcher acts on it at the next event.
        h.environment.frontmost = Self.excludedApp
        h.resetSignal.request()
        _ = h.up(0)
        #expect(h.matcher.holdsNoCharacters)
    }

    @Test func theWordTypedBeforeFocusMovedNeverJoinsWhatIsTypedInTheExcludedApp() {
        let h = harness(excluded: ["com.example.terminal"])
        h.type(";s")
        h.environment.frontmost = Self.excludedApp
        h.resetSignal.request()
        h.type("ig")
        // ";s" was dropped at the focus change, so this is "ig", not ";sig".
        #expect(h.space() == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    @Test func aTriggerTypedInAnExcludedAppIsSuppressedAndLeavesTheBufferEmpty() {
        let h = harness(excluded: ["com.example.terminal"])
        h.environment.frontmost = Self.excludedApp
        h.type(";sig")
        #expect(h.space() == .suppressed(.excludedApp))
        #expect(h.matcher.holdsNoCharacters)
    }

    @Test func aNonTriggerWordTypedInAnExcludedAppLeavesTheBufferEmptyAtItsBoundary() {
        let h = harness(excluded: ["com.example.terminal"])
        h.environment.frontmost = Self.excludedApp
        h.type("s3cretpassword")
        #expect(h.space() == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }
}
