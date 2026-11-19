import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// TASK-499 blind QA (OC-499-W01..W09): FR-005-13 e / FR-005-20 with no identifiable frontmost application.
@Suite struct Worf499AdversarialTests {
    private static let unknownApps = [nil, FrontmostApp(bundleId: nil, processId: 7)] as [FrontmostApp?]
    private static let editor = FrontmostApp(bundleId: "com.example.editor", processId: 100)

    private func harness(_ triggers: [UUID: String], in app: FrontmostApp?) -> MatcherHarness {
        let h = MatcherHarness(triggers: triggers, excluded: [])
        h.environment.frontmost = app
        return h
    }

    // OC-499-W01: given no app and trigger ';sig', when ';sx' then ';sig' is typed in the same word and Space pressed,
    // then the word stays dead (nothing held at any point, Space passes). Red if a dead word revived.
    @Test(arguments: unknownApps)
    func aMistypedWordStaysDeadEvenWhenATriggerFollowsInTheSameWord(app: FrontmostApp?) {
        let h = harness([UUID(): ";sig"], in: app)
        h.type(";s")
        #expect(!h.matcher.holdsNoCharacters)
        h.type("x")
        #expect(h.matcher.holdsNoCharacters)
        h.type(";sig")
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
        // and the next word is live again
        h.type(";sig")
        #expect(h.space() == .suppressed(.unknownApp))
    }

    // OC-499-W02: given no app, when U+037E 'sig' is typed (canonically ';'), then it is held as a prefix and the
    // boundary is suppressed as unknown. Red if the prefix test compared raw scalars.
    @Test(arguments: unknownApps)
    func greekQuestionMarkIsHeldAsTheSemicolonPrefix(app: FrontmostApp?) {
        let h = harness([UUID(): ";sig"], in: app)
        h.type("\u{037E}s")
        #expect(!h.matcher.holdsNoCharacters)
        h.type("ig")
        #expect(h.space() == .suppressed(.unknownApp))
    }

    // OC-499-W03: given no app, when ';SiG' (mixed case) typed, then held and suppressed; ';SX' dies.
    @Test(arguments: unknownApps)
    func prefixCheckIsCaseInsensitive(app: FrontmostApp?) {
        let h = harness([UUID(): ";sig"], in: app)
        h.type(";SiG")
        #expect(!h.matcher.holdsNoCharacters)
        #expect(h.space() == .suppressed(.unknownApp))
        h.type(";SX")
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-499-W04: boundary lengths 0/1/max/max+1 with a 24-char trigger and no app.
    @Test(arguments: unknownApps)
    func boundaryLengthsWithNoApplication(app: FrontmostApp?) {
        let trigger = ";" + String(repeating: "a", count: 23)
        let h = harness([UUID(): trigger], in: app)
        #expect(h.matcher.holdsNoCharacters)                      // 0 typed
        h.type(";")
        #expect(!h.matcher.holdsNoCharacters)                      // 1 typed: a prefix
        h.type(String(repeating: "a", count: 22))
        #expect(!h.matcher.holdsNoCharacters)                      // 23 typed: a prefix
        h.type("a")
        #expect(!h.matcher.holdsNoCharacters)                      // 24 typed: the whole trigger
        #expect(h.space() == .suppressed(.unknownApp))
        h.type(trigger + "a")                                      // 25 typed: beyond max
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
    }

    // OC-499-W05: given no app and a whole trigger typed, when Secure Event Input is on, then secure input wins (it is
    // the only outcome that is logged), and the buffer is empty after.
    @Test(arguments: unknownApps)
    func secureInputOutranksUnknownApp(app: FrontmostApp?) {
        let h = harness([UUID(): ";sig"], in: app)
        h.environment.secureInput = true
        h.type(";sig")
        #expect(h.space() == .suppressed(.secureInput))
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-499-W06: given a word begun with no app, when the engine's app-change signal fires and an ordinary app is
    // frontmost, then the next word is NOT limited (the limit is per word, cleared by the reset).
    @Test func theAppChangeSignalLiftsTheLimitForTheNextWord() {
        let h = harness([UUID(): ";sig"], in: nil)
        h.type(";s")
        #expect(!h.matcher.holdsNoCharacters)
        h.resetSignal.request()
        h.environment.frontmost = Self.editor
        h.type("hello")
        #expect(!h.matcher.holdsNoCharacters)
    }

    // OC-499-W07: given a word begun with no app, when the app becomes known before the boundary, then the match is
    // not honoured (the word began elsewhere): .pass, never .matched.
    @Test func aWordBegunWithNoAppNeverMatchesInALaterKnownApp() {
        let h = harness([UUID(): ";sig"], in: nil)
        h.type(";sig")
        h.environment.frontmost = Self.editor
        let r = h.space()
        #expect(r == .pass)
        #expect(r.match == nil)
    }

    // OC-499-W08: given no app, when the word goes idle 6 s or Flotsam posts its own event, then it is emptied.
    @Test(arguments: unknownApps)
    func idleAndOwnEventsEmptyTheWord(app: FrontmostApp?) {
        let h = harness([UUID(): ";sig"], in: app)
        h.type(";si")
        #expect(!h.matcher.holdsNoCharacters)
        h.clock.advance(6)
        h.type("g")   // the idle timeout clears ";si" first, so "g" alone is not a prefix
        #expect(h.matcher.holdsNoCharacters)
        _ = h.space()   // "g" killed that word; the boundary starts a fresh one
        h.type(";si")
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.matcher.process(KeyEvent(kind: .keyDown, keyCode: 0, flags: [], characters: "z", isFlotsamEvent: true))
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-499-W09: given no app, when Backspace empties the word and one more Backspace arrives, then the word is dead.
    @Test(arguments: unknownApps)
    func backspacePastTheStartKillsTheWord(app: FrontmostApp?) {
        let h = harness([UUID(): ";sig"], in: app)
        h.type(";s")
        for _ in 0..<3 { _ = h.down(TriggerKeys.backspace) }
        #expect(h.matcher.holdsNoCharacters)
        h.type(";sig")
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
    }
}
