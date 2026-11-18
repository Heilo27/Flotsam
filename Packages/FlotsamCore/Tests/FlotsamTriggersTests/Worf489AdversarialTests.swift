import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// Worf blind QA for TASK-489 (security F-04 residual, FR-005-11 / FR-005-20): in an excluded application the word
/// buffer holds a word only while it is the start of some trigger or a whole trigger.
/// The seam is `TriggerMatcher.holdsNoCharacters` (the matcher's own state) plus what each boundary key returns.
/// Every "buffer is empty" check is preceded by a "buffer is not empty" check on the same word, so it can fail.
@Suite struct Worf489AdversarialTests {
    private let sig = UUID()
    private let sign = UUID()
    private let addr = UUID()
    private let mixed = UUID()
    private static let terminal = "com.example.terminal"
    private static let editor = FrontmostApp(bundleId: "com.example.editor", processId: 100)
    private static let terminalApp = FrontmostApp(bundleId: terminal, processId: 200)

    private var triggers: [UUID: String] { [sig: ";sig", sign: ";sign", addr: ".addr", mixed: ";Sig-9_x"] }

    /// A harness whose frontmost app is `app` (the terminal by default: the excluded one).
    private func harness(
        in app: FrontmostApp? = terminalApp, triggers override: [UUID: String]? = nil
    ) -> MatcherHarness {
        let h = MatcherHarness(triggers: override ?? triggers, excluded: [Self.terminal])
        h.environment.frontmost = app
        return h
    }

    // MARK: AC 1: the buffer is empty once the word stops being a trigger prefix

    // OC-489-W01: given an excluded app, when ";s" then "x" is typed, then ";s" is held and the "x" empties the buffer;
    // the rest of the word holds nothing and the boundary passes untouched.
    @Test func excludedAppDropsTheWordAtTheFirstNonPrefixCharacter() {
        let h = harness()
        h.type(";s")
        #expect(!h.matcher.holdsNoCharacters)
        h.type("x")
        #expect(h.matcher.holdsNoCharacters)
        for ch in "yzzy" {
            h.type(String(ch))
            #expect(h.matcher.holdsNoCharacters, "after '\(ch)'")
        }
        #expect(h.space() == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-489-W02: given an excluded app, when ordinary words are typed, then the buffer is empty after every key
    // (the first character is already not a prefix: no trigger starts with a letter).
    @Test func ordinaryTypingInAnExcludedAppHoldsNothingAtAnyKey() {
        let h = harness()
        for ch in "hello world, this is ordinary prose 12345" {
            if ch == " " { _ = h.space() } else { h.type(String(ch)) }
            #expect(h.matcher.holdsNoCharacters, "after '\(ch)'")
        }
    }

    // OC-489-W03: given an excluded app, when a word is mistyped and a trigger follows in the same word, then the
    // dead word stays dead (not logged), and the next word after a boundary is live again.
    @Test func aMistypedCharacterKillsTheWordEvenIfATriggerFollows() {
        let h = harness()
        h.type("x;sig")
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)  // FR-005-20: a trigger after a dropped character is not logged
        h.type(";sig")
        #expect(!h.matcher.holdsNoCharacters)
        #expect(h.space() == .suppressed(.excludedApp))  // the boundary made the word live again
    }

    // OC-489-W04: given a dead word in an excluded app, when Backspace removes the mistyped character and the
    // trigger is completed, then the word stays dead (Backspace does not revive it) and nothing is held.
    @Test func backspaceDoesNotReviveADroppedWord() {
        let h = harness()
        h.type(";sx")
        #expect(h.matcher.holdsNoCharacters)
        _ = h.down(TriggerKeys.backspace)
        h.type("ig")
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
    }

    // OC-489-W05: given an excluded app, when a held prefix is Backspaced down, then the remaining prefix is still
    // held, and completing the trigger after the edit still logs TRG-POL-002.
    @Test func backspacingInsideTheTriggerPrefixKeepsTheWordLive() {
        let h = harness()
        h.type(";sig")
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.down(TriggerKeys.backspace)
        #expect(!h.matcher.holdsNoCharacters)  // ";si" is still held
        h.type("g")
        #expect(h.space() == .suppressed(.excludedApp))
    }

    // OC-489-W06: given an excluded app and an empty buffer, when Backspace arrives, then the word is dead
    // (pre-existing FR-005-11 rule still holds) and a following trigger is not held.
    @Test func backspaceOnAnEmptyBufferStillKillsTheWord() {
        let h = harness()
        _ = h.down(TriggerKeys.backspace)
        h.type(";sig")
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
    }

    // OC-489-W07: given an excluded app and NO triggers defined, when anything is typed, then nothing is ever held.
    @Test func excludedAppWithNoTriggersHoldsNothing() {
        let h = harness(triggers: [:])
        for ch in ";sig.addr" {
            h.type(String(ch))
            #expect(h.matcher.holdsNoCharacters, "after '\(ch)'")
        }
        #expect(h.space() == .pass)
    }

    // MARK: AC 2: a full trigger in an excluded app is still logged and never expands

    // OC-489-W08: given an excluded app, when each trigger is typed and ended by each boundary key, then every result is
    // .suppressed(.excludedApp) (TRG-POL-002), never .matched, the boundary key passes through, and the buffer is empty.
    @Test(arguments: [TriggerKeys.space, TriggerKeys.tab, TriggerKeys.returnKey, TriggerKeys.keypadEnter])
    func fullTriggerInAnExcludedAppIsSuppressedOnEveryBoundaryKey(boundary: UInt16) {
        for text in [";sig", ";sign", ".addr", ";Sig-9_x"] {
            let h = harness()
            h.type(text)
            #expect(!h.matcher.holdsNoCharacters, "\(text) is held to its boundary")
            let result = h.down(boundary, " ")
            #expect(result == .suppressed(.excludedApp), "\(text)")
            #expect(result.match == nil)
            #expect(result.decision == .pass)
            #expect(h.matcher.holdsNoCharacters)
            // the key-up of an un-swallowed boundary key is not swallowed either
            #expect(h.up(boundary) == .pass)
        }
    }

    // OC-489-W09: given an excluded app, when ";sig" is typed after a dropped word and a boundary, then TRG-POL-002 again
    // (the flag does not stick to a later word), and a non-trigger word between them holds nothing.
    @Test func suppressionRepeatsWordAfterWordInAnExcludedApp() {
        let h = harness()
        for _ in 0..<3 {
            h.type(";sig")
            #expect(h.space() == .suppressed(.excludedApp))
            h.type("plain")
            #expect(h.matcher.holdsNoCharacters)
            #expect(h.space() == .pass)
        }
    }

    // MARK: AC 3 (regression guard): non-excluded apps behave as before

    // OC-489-W10: given a non-excluded app with overlapping triggers ";sig" and ";sign", when each is typed, then each
    // expands to its own item, and the shorter one is not swallowed by the longer.
    @Test func overlappingPrefixTriggersExpandAsBeforeInAnOrdinaryApp() {
        let h = harness(in: Self.editor)
        #expect(h.type(";sig").allSatisfy { $0 == .pass })
        #expect(h.space().match?.itemId == sig)
        h.type(";sign")
        let second = h.space().match
        #expect(second?.itemId == sign)
        #expect(second?.triggerLength == 5)
        #expect(second?.typedText == ";sign")
        h.type(";SIGN")  // case-insensitive
        #expect(h.space().match?.itemId == sign)
    }

    // OC-489-W11: given a non-excluded app, when a non-trigger word is typed, then it is still buffered (the prefix guard
    // applies to excluded apps only); Backspace edits the word as before, and "x;sig" is simply no trigger.
    @Test func ordinaryAppStillBuffersEveryCharacterOfAWord() {
        let h = harness(in: Self.editor)
        h.type("hello")
        #expect(!h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
        h.type(";sigx")  // not a prefix of any trigger, held anyway
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.down(TriggerKeys.backspace)
        #expect(!h.matcher.holdsNoCharacters)
        #expect(h.space().match?.itemId == sig)  // ";sig" after the Backspace: the word was never dropped
        h.type("x;sig")
        #expect(h.space() == .pass)
    }

    // OC-489-W12: given two items with the same trigger (ambiguous), when it is typed in an ordinary app, then nothing
    // expands; in an excluded app the ambiguous word is not a prefix and is dropped at its first non-prefix character.
    @Test func ambiguousTriggerIsDroppedFromMatchingAndFromThePrefixSet() {
        let a = UUID(), b = UUID(), c = UUID()
        let dup: [UUID: String] = [a: ";dup", b: ";DUP", c: ";sig"]
        let ordinary = harness(in: Self.editor, triggers: dup)
        ordinary.type(";dup")
        #expect(ordinary.space() == .pass)
        ordinary.type(";sig")
        #expect(ordinary.space().match?.itemId == c)

        let excluded = harness(triggers: dup)
        excluded.type(";")
        #expect(!excluded.matcher.holdsNoCharacters)  // ";" starts ";sig"
        excluded.type("d")
        #expect(excluded.matcher.holdsNoCharacters)  // ";d" would only start the dropped ambiguous key
        #expect(excluded.space() == .pass)
        excluded.type(";sig")
        #expect(excluded.space() == .suppressed(.excludedApp))
    }

    // OC-489-W13: given an ambiguous short key that is the start of a longer unique key, when typed in an excluded app,
    // then it is held as a prefix of the longer one but is not a match on its own.
    @Test func ambiguousKeyThatPrefixesAUniqueKeyIsHeldButNeverMatched() {
        let a = UUID(), b = UUID(), c = UUID()
        let t: [UUID: String] = [a: ";dup", b: ";Dup", c: ";dupe"]
        let h = harness(triggers: t)
        h.type(";dup")
        #expect(!h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
        h.type(";dupe")
        #expect(h.space() == .suppressed(.excludedApp))
    }

    // MARK: removing(_:) rebuilds the prefix set

    // OC-489-W14: given ";sig" and ";sign", when the ";sign" item is removed from the store, then in an excluded app
    // ";sign" is no longer held past ";sig" while ";sig" itself still is.
    @Test func removingAnItemRebuildsThePrefixSet() {
        let h = harness()
        h.type(";sign")
        #expect(!h.matcher.holdsNoCharacters)  // before: ";sign" is a whole trigger
        _ = h.space()
        h.store.remove(itemIds: [sign])
        h.type(";sig")
        #expect(!h.matcher.holdsNoCharacters)
        h.type("n")
        #expect(h.matcher.holdsNoCharacters)  // after: ";sign" is no prefix of anything
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space() == .suppressed(.excludedApp))
    }

    // OC-489-W15: given the only trigger starting with "." , when it is removed, then "." is dropped at once.
    @Test func removingTheLastKeyOfAPrefixDropsThatPrefix() {
        let h = harness()
        h.type(".")
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.space()
        h.store.remove(itemIds: [addr])
        h.type(".")
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-489-W16: given a rebuild in flight, when an item is deleted and the late read installs, then the installed
    // snapshot's prefix set also leaves out the deleted trigger (the removal inside `replace` rebuilds it too).
    @Test func aDeleteDuringARebuildLeavesTheDeletedTriggerOutOfThePrefixSet() {
        let h = harness()
        let token = h.store.beginRebuild()
        h.store.remove(itemIds: [addr])
        #expect(h.store.replace(TriggerSnapshot(bindings: ItemBindings(triggers: triggers)), token: token))
        h.type(".")
        #expect(h.matcher.holdsNoCharacters)
        _ = h.space()
        h.type(";sign")
        #expect(h.space() == .suppressed(.excludedApp))  // everything else it read is still installed
    }

    // OC-489-W17: given a replaced snapshot, when the new set has fewer triggers, then the old prefixes do not linger
    // and a newly saved trigger is held at once.
    @Test func installingANewSnapshotReplacesThePrefixSet() {
        let h = harness()
        h.type(".a")
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.space()
        h.install([UUID(): "!bang"])
        h.type(".a")
        #expect(h.matcher.holdsNoCharacters)  // ".addr" is gone
        _ = h.space()
        h.type("!ba")
        #expect(!h.matcher.holdsNoCharacters)
        h.type("ng")
        #expect(h.space() == .suppressed(.excludedApp))
    }

    // OC-489-W18: the snapshot's own prefix question, directly: whole keys and every proper prefix are true; extensions,
    // other words, the empty string and a non-canonical (upper-case) key are false.
    @Test func isPrefixOfSomeKeyAnswersExactlyTheStartsOfKeys() {
        let snapshot = TriggerSnapshot(bindings: ItemBindings(triggers: [sig: ";sig", mixed: ";Sig-9_x"]))
        for yes in [";", ";s", ";si", ";sig", ";sig-", ";sig-9", ";sig-9_", ";sig-9_x"] {
            #expect(snapshot.isPrefixOfSomeKey(yes), "\(yes)")
        }
        for no in ["", "s", "sig", ";sigs", ";sx", ";sig-9_xx", ";SIG", ";Sig-9_x", "; sig", ";sig\u{0301}"] {
            #expect(!snapshot.isPrefixOfSomeKey(no), "\(no)")
        }
        #expect(!TriggerSnapshot.empty.isPrefixOfSomeKey(";"))
        let removed = snapshot.removing([mixed])
        #expect(!removed.isPrefixOfSomeKey(";sig-"))
        #expect(removed.isPrefixOfSomeKey(";sig"))
        #expect(removed.count == 1)
        #expect(snapshot.isPrefixOfSomeKey(";sig-"))  // the original is a value: unchanged
    }

    // MARK: Canonicalization and the 24-character limit

    // OC-489-W19: given the trigger ";Sig-9_x", when it is typed in any case in an excluded app, then it is held the whole
    // way and logged; lookup is by the canonical (ASCII-lower-cased) key on both sides.
    @Test(arguments: [";Sig-9_x", ";sig-9_x", ";SIG-9_X", ";sIg-9_X"])
    func caseDoesNotChangeWhetherAWordIsAPrefixInAnExcludedApp(typed: String) {
        let h = harness()
        for ch in typed {
            h.type(String(ch))
            #expect(!h.matcher.holdsNoCharacters, "after '\(ch)' of \(typed)")
        }
        #expect(h.space() == .suppressed(.excludedApp))
    }

    // OC-489-W20: given an excluded app, when a non-ASCII look-alike of a trigger character is typed, then the word is
    // dropped there (ASCII-only fold): dotless i, capital dotted I, full-width letters, Kelvin sign, a combining mark.
    @Test(arguments: [";s\u{0131}g", ";S\u{0130}G", ";\u{FF53}ig", ";s\u{FF49}g", ";sig\u{0301}", ";\u{212A}g", "\u{FF1B}sig"])
    func nonAsciiLookAlikesAreNotPrefixes(typed: String) {
        let h = harness(triggers: [sig: ";sig", UUID(): ";kg"])
        for ch in typed { h.type(String(ch)) }
        #expect(h.matcher.holdsNoCharacters, "\(typed.unicodeScalars.map(\.value))")
        #expect(h.space() == .pass)
    }

    // OC-489-W21: given a 24-character trigger (the maximum), when it is typed in an excluded app, then all 24 are held
    // and it is logged; at 25 characters the word is dropped; at 23 it is simply a prefix (held, not a match).
    @Test func twentyFourCharacterBoundaryInAnExcludedApp() {
        let t24 = ";" + String(repeating: "a", count: 23)
        #expect(t24.count == 24)
        let longId = UUID()
        let t: [UUID: String] = [longId: t24, sig: ";sig"]

        let full = harness(triggers: t)
        full.type(t24)
        #expect(!full.matcher.holdsNoCharacters)
        #expect(full.space() == .suppressed(.excludedApp))

        let over = harness(triggers: t)
        over.type(t24)
        #expect(!over.matcher.holdsNoCharacters)
        over.type("a")  // 25th
        #expect(over.matcher.holdsNoCharacters)
        #expect(over.space() == .pass)

        let short = harness(triggers: t)
        short.type(String(t24.dropLast()))
        #expect(!short.matcher.holdsNoCharacters)
        #expect(short.space() == .pass)  // 23 characters: a prefix, not a trigger
    }

    // OC-489-W22: same boundary in an ordinary app: 24 expands, 25 is dropped and never expands.
    @Test func twentyFourCharacterBoundaryInAnOrdinaryApp() {
        let t24 = ";" + String(repeating: "a", count: 23)
        let longId = UUID()
        let h = harness(in: Self.editor, triggers: [longId: t24])
        h.type(t24)
        #expect(h.space().match?.itemId == longId)
        h.type(t24 + "a")
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
    }

    // OC-489-W23: given an excluded app, when a trigger body uses every allowed body character class, then each is a
    // held prefix step (digits, hyphen, underscore, mixed case), and a character just outside the class is not.
    @Test func bodyCharacterClassesAreAllHeldAndTheNextOneOutIsNot() {
        let h = harness()
        h.type(";Sig-9_")
        #expect(!h.matcher.holdsNoCharacters)
        h.type("!")  // a symbol is not a body character
        #expect(h.matcher.holdsNoCharacters)
    }

    // MARK: Word-start exclusion versus a mid-word app switch

    // OC-489-W24: given a word begun in an ordinary app, when focus moves to the excluded app and the engine's reset
    // signal is raised, then the next key starts a fresh word there and a non-prefix character holds nothing.
    @Test func afterTheResetSignalTheExcludedAppIsDecidedForTheNewWord() {
        let h = harness(in: Self.editor)
        h.type(";si")
        #expect(!h.matcher.holdsNoCharacters)
        h.environment.frontmost = Self.terminalApp
        h.resetSignal.request()
        h.type("x")
        #expect(h.matcher.holdsNoCharacters)
        #expect(h.space() == .pass)
    }

    // OC-489-W25: given a word begun in an ordinary app, when focus moves to the excluded app and NO reset arrives, then
    // the boundary key there never expands (the word began elsewhere) and leaves the buffer empty. The exclusion was
    // decided at word start (documented lazy clear, ADR-0007), so the characters are held until that boundary.
    @Test func aWordBegunInAnOrdinaryAppNeverExpandsInAnExcludedApp() {
        let h = harness(in: Self.editor)
        h.type(";si")
        h.environment.frontmost = Self.terminalApp
        h.type("x")  // not a trigger prefix: an excluded app decided per character would drop it here
        #expect(!h.matcher.holdsNoCharacters)  // decided once, at the word's first character
        let result = h.space()
        #expect(result.match == nil)
        #expect(result == .pass)
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-489-W26: given a word begun in the excluded app, when focus moves to an ordinary app with no reset, then the
    // word stays prefix-limited (decided once) and its boundary there neither expands nor logs; the next word in the
    // ordinary app is buffered normally (the flag does not stick).
    @Test func aWordBegunInAnExcludedAppIsNotKeptByTheOrdinaryAppItEndsIn() {
        let h = harness()
        h.type(";si")
        #expect(!h.matcher.holdsNoCharacters)
        h.environment.frontmost = Self.editor
        h.type("x")  // an ordinary app decided per character would keep it
        #expect(h.matcher.holdsNoCharacters)  // the word began in the terminal: still prefix-limited
        #expect(h.space() == .pass)  // began in the terminal: not a match here, not logged
        h.type("hello")
        #expect(!h.matcher.holdsNoCharacters)  // the new word began in the editor
        #expect(h.space() == .pass)
        h.type(";sig")
        #expect(h.space().match?.itemId == sig)
    }

    // OC-489-W27: given a word begun in an ordinary app, when the app is added to the excluded list mid-word, then the
    // boundary key suppresses (TRG-POL-002) and never expands.
    @Test func excludingTheAppMidWordSuppressesAtTheBoundary() {
        let h = harness(in: Self.editor)
        h.type(";sig")
        h.store.setExcludedApps([Self.editor.bundleId!])
        #expect(h.space() == .suppressed(.excludedApp))
        #expect(h.matcher.holdsNoCharacters)
    }

    // OC-489-W28: given an excluded app word that was dropped, when the idle timeout passes and a new word starts, then
    // the new word is live (the dead flag is cleared by the timeout too) and still prefix-limited.
    @Test func idleTimeoutRevivesTheWordButNotTheRetention() {
        let h = harness()
        h.type("x")
        #expect(h.matcher.holdsNoCharacters)
        h.clock.advance(6)
        h.type(";sig")
        #expect(!h.matcher.holdsNoCharacters)
        #expect(h.space() == .suppressed(.excludedApp))
        h.type(";sx")
        #expect(h.matcher.holdsNoCharacters)
    }

    // MARK: Flotsam's own bundle id and the unknown frontmost app

    // OC-489-W29: given Flotsam itself frontmost (not in the editable list), when ordinary text is typed, then nothing is
    // held, and a full trigger is suppressed as an excluded app.
    @Test func flotsamsOwnBundleIdIsLimitedLikeAnExcludedApp() {
        let h = harness(in: FrontmostApp(bundleId: MatcherHarness.ownBundleId, processId: 1))
        h.store.setExcludedApps([])
        h.type(";s")
        #expect(!h.matcher.holdsNoCharacters)
        h.type("x")
        #expect(h.matcher.holdsNoCharacters)
        _ = h.space()
        h.type("hello")
        #expect(h.matcher.holdsNoCharacters)
        _ = h.space()
        h.type(";sig")
        #expect(h.space() == .suppressed(.excludedApp))
    }

    // OC-489-W30: given no frontmost app, or one with no bundle id, when a trigger is typed and ended by each boundary
    // key, then it never expands (fail closed, FR-005-13 e), is not logged as TRG-POL-002, and the buffer is empty after.
    @Test(arguments: [nil, FrontmostApp(bundleId: nil, processId: 7)] as [FrontmostApp?])
    func unknownFrontmostAppNeverExpands(app: FrontmostApp?) {
        for boundary in [TriggerKeys.space, TriggerKeys.tab, TriggerKeys.returnKey, TriggerKeys.keypadEnter] {
            let h = harness(in: app)
            h.type(";sig")
            let result = h.down(boundary, " ")
            #expect(result == .suppressed(.unknownApp))
            #expect(result.match == nil)
            #expect(h.matcher.holdsNoCharacters)
        }
    }

    // MARK: Latency of the new check (AC-005-20 / OC-5129 covers the ordinary app; this covers the excluded one)

    // OC-489-W31: given 100 triggers and an excluded app, when 1,000 key events are processed (prefix words, long dropped
    // words, backspaces, full triggers), then p99 of the callback is at most 1 ms and the script really suppressed.
    @Test func excludedAppCallbackStaysUnderOneMillisecondAtP99() {
        var triggers: [UUID: String] = [:]
        for index in 0..<100 { triggers[UUID()] = ";w\(String(format: "%03d", index))" }
        let texts = Array(triggers.values)
        let h = harness(triggers: triggers)
        var events: [KeyEvent] = []
        func key(_ code: UInt16, _ characters: String) {
            events.append(KeyEvent(kind: .keyDown, keyCode: code, characters: characters))
            events.append(KeyEvent(kind: .keyUp, keyCode: code, characters: characters))
        }
        var word = 0
        while events.count < 1_400 {
            let text = switch word % 3 {
            case 0: texts[(word / 3) % texts.count]
            case 1: "plainword\(word)-with-a-long-tail"
            default: ";w0\(word % 10)x"
            }
            for ch in text { key(0, String(ch)) }
            if word % 3 == 2 { key(TriggerKeys.backspace, "") }
            key(TriggerKeys.space, " ")
            word += 1
        }
        for event in events.prefix(200) { _ = h.matcher.process(event) }
        let clock = ContinuousClock()
        var samples: [Double] = []
        var suppressed = 0
        for event in events.dropFirst(200).prefix(1_000) {
            var result = MatcherResult.pass
            let elapsed = clock.measure { result = h.matcher.process(event) }
            samples.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            if case .suppressed(.excludedApp) = result { suppressed += 1 }
            if case .matched = result { Issue.record("expanded in an excluded app") }
        }
        let sorted = samples.sorted()
        let p99 = sorted[Int((0.99 * Double(sorted.count)).rounded(.up)) - 1]
        #expect(suppressed >= 10)
        #expect(p99 <= 0.001, "p99 \(p99 * 1000) ms")
    }
}
