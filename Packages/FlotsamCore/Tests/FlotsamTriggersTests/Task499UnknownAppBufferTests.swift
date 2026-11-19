import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// TASK-499 (FR-005-13 e, FR-005-20): with no frontmost application, or one without a bundle identifier, the word
/// buffer is limited exactly like an excluded application's: it holds a word only while it is the start of some trigger
/// or a whole trigger, so ordinary typing holds nothing. Every "empty" check follows a "not empty" check on a trigger
/// prefix typed under the same conditions, so it can fail.
@Suite struct Task499UnknownAppBufferTests {
    private let sig = UUID()
    private static let unknownApps = [nil, FrontmostApp(bundleId: nil, processId: 7)] as [FrontmostApp?]

    private func harness(in app: FrontmostApp?) -> MatcherHarness {
        let h = MatcherHarness(triggers: [sig: ";sig"], excluded: ["com.example.terminal"])
        h.environment.frontmost = app
        return h
    }

    @Test(arguments: unknownApps)
    func ordinaryTypingWithAnUnknownFrontmostAppHoldsNothing(app: FrontmostApp?) {
        let h = harness(in: app)
        h.type(";s")
        #expect(!h.matcher.holdsNoCharacters, "a trigger prefix is still held, so the empty checks below are not vacuous")
        _ = h.space()
        for ch in "hello world, up to twenty-four characters of prose" {
            if ch == " " { _ = h.space() } else { h.type(String(ch)) }
            #expect(h.matcher.holdsNoCharacters, "after '\(ch)'")
        }
    }

    @Test(arguments: unknownApps)
    func aMistypedCharacterEmptiesTheBufferAndKillsTheWordUntilTheNextBoundary(app: FrontmostApp?) {
        let h = harness(in: app)
        h.type(";s")
        #expect(!h.matcher.holdsNoCharacters)
        h.type("x")
        #expect(h.matcher.holdsNoCharacters)
        h.type("ig")
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
    }

    @Test(arguments: unknownApps)
    func aWholeTriggerIsStillHeldToItsBoundaryAndSuppressedAsUnknown(app: FrontmostApp?) {
        let h = harness(in: app)
        h.type(";sig")
        #expect(!h.matcher.holdsNoCharacters)
        #expect(h.space() == .suppressed(.unknownApp))
        #expect(h.matcher.holdsNoCharacters)
    }

    // The limit must come from the current word's own application, not from the word before it: an excluded word
    // followed by a word with no known application stays limited, and a known ordinary application is not limited.
    @Test func theLimitFollowsTheApplicationOfEachWord() {
        let h = harness(in: FrontmostApp(bundleId: "com.example.terminal", processId: 200))
        h.type(";s")
        _ = h.space()
        h.environment.frontmost = nil
        h.type("hello")
        #expect(h.matcher.holdsNoCharacters)
        _ = h.space()
        h.environment.frontmost = FrontmostApp(bundleId: "com.example.editor", processId: 100)
        h.type("hello")
        #expect(!h.matcher.holdsNoCharacters)
    }
}

/// TASK-499 issue 4, superseded by TASK-493 (FR-005-11, Ryan's ruling): any typed non-ASCII scalar kills the word, even
/// one that Unicode normalises to ASCII, so the Greek question mark (U+037E, canonically ";") does not type a ";" trigger.
@Suite struct Task499GrammarNormalisationTests {
    // OC-5152: given trigger ";sig", when U+037E "sig" is typed then Space, then nothing matches (the word is dead);
    // and the next word ";sig" Space matches. Red if canonical equivalence were allowed to fold U+037E to ";".
    @Test func greekQuestionMarkKillsTheWordInsteadOfMatchingTheSemicolonTrigger() {
        let id = UUID()
        let h = MatcherHarness(triggers: [id: ";sig"], excluded: [])
        h.type("\u{037E}sig")
        #expect(h.space().match == nil)
        h.type(";sig")
        #expect(h.space().match?.itemId == id)
    }

    @Test func theEditorStillRejectsANonAsciiTrigger() {
        if case .success = TriggerGrammar.validate("\u{037E}sig") { Issue.record("grammar accepted U+037E") }
    }
}
