import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// TASK-493 (FR-005-11 / AC-005-10): Ryan ruled on 2026-11-18 that any non-ASCII character typed into the current word
/// stops that word from matching until the next boundary, even if it is Backspaced away. Source of the Thai repro:
/// trigger `:ab`, type ก and a Thai mark, Backspace, Space. A Thai text field deletes one mark per Backspace, so the
/// word's real contents are unknown after such input; the old behaviour re-matched `:ab` and over-deleted.
@Suite struct Task493NonAsciiKillsWordTests {
    private let ab = UUID()
    private let thai = "\u{0E01}"  // KO KAI
    private let thaiMark = "\u{0E31}"  // MAI HAN-AKAT, a combining mark
    private let backspace = TriggerKeys.backspace

    private func harness() -> MatcherHarness { MatcherHarness(triggers: [ab: ":ab"]) }

    // AC2: the Thai repro fires nothing, so nothing is deleted (a match is what makes the engine post Backspaces).
    @Test func thaiReproFiresNothingAndDeletesNothing() {
        let h = harness()
        h.type(":ab")
        _ = h.down(0, thai)
        _ = h.down(0, thaiMark)
        #expect(h.down(backspace) == .pass)
        let result = h.space()
        #expect(result == .pass)
        #expect(result.match == nil)
        #expect(result.decision == .pass)  // the Space is typed, not swallowed
    }

    // AC1: the word stays dead however many Backspaces follow, including ones that leave only ASCII in the field.
    @Test(arguments: 1...6)
    func theWordStaysDeadWhateverTheBackspaceCount(backspaces: Int) {
        let h = harness()
        h.type(":ab")
        _ = h.down(0, thai)
        _ = h.down(0, thaiMark)
        for _ in 0..<backspaces { _ = h.down(backspace) }
        h.type(":ab")  // retyped on top, whatever the field holds
        #expect(h.space() == .pass)
    }

    // Any non-ASCII character, not only combining marks, at the start, middle or end of the word.
    @Test(arguments: ["\u{00E9}", "\u{0301}", "\u{0E01}", "\u{4E2D}", "\u{1F600}", "\u{1F1FA}\u{1F1F8}", "\u{FF21}", "\u{00A0}"])
    func anyNonAsciiCharacterKillsTheWord(character: String) {
        for position in 0...3 {
            let h = harness()
            let letters = Array(":ab").map(String.init)
            for (index, letter) in letters.enumerated() {
                if index == position { _ = h.down(0, character) }
                _ = h.down(0, letter)
            }
            if position == 3 { _ = h.down(0, character) }
            #expect(h.matcher.holdsNoCharacters, "position \(position)")
            _ = h.down(backspace)
            #expect(h.space() == .pass, "position \(position)")
        }
    }

    // The word's kill ends at the next boundary: the next word matches normally, with the right length.
    @Test func theNextWordAfterABoundaryMatchesNormally() throws {
        let h = harness()
        h.type(":ab")
        _ = h.down(0, thai)
        _ = h.down(0, thaiMark)
        _ = h.down(backspace)
        #expect(h.space() == .pass)
        h.type(":ab")
        let match = try #require(h.space().match)
        #expect(match.itemId == ab)
        #expect(match.typedText == ":ab")
        #expect(match.triggerLength == 3)
    }

    // A reset (Esc, mouse click, arrow) also ends the dead word, same as a boundary.
    @Test func aMouseClickEndsTheDeadWord() throws {
        let h = harness()
        h.type(":ab")
        _ = h.down(0, thai)
        _ = h.matcher.process(KeyEvent(kind: .mouseDown))
        h.type(":ab")
        #expect(try #require(h.space().match).triggerLength == 3)
    }

    // Unchanged: plain ASCII triggers, case folding, Backspace editing and the case where a non-ASCII word precedes.
    @Test func plainAsciiTriggersAreUnchanged() throws {
        let h = harness()
        h.type(":ab")
        #expect(try #require(h.space().match).triggerLength == 3)
        h.type(":AB")
        #expect(h.space().match?.itemId == ab)
        h.type(":ax")
        _ = h.down(backspace)
        h.type("b")
        #expect(h.space().match?.itemId == ab)  // ASCII Backspace still edits the word
    }

    @Test func aNonAsciiWordBeforeTheBoundaryDoesNotAffectTheTriggerThatFollows() throws {
        let h = harness()
        h.type("caf\u{00E9}")
        #expect(h.space() == .pass)
        h.type(":ab")
        #expect(try #require(h.space().match).typedText == ":ab")
    }

    // A non-ASCII event on an already dead word is ignored without trapping (e.g. 25th character, then a mark).
    @Test func aMarkOnAnAlreadyDeadWordChangesNothing() throws {
        let h = harness()
        _ = h.down(backspace)  // empty buffer: dead
        _ = h.down(0, thaiMark)
        #expect(h.space() == .pass)
        h.type(":ab")
        #expect(try #require(h.space().match).triggerLength == 3)
    }

    // Security F-04 still holds: after a non-ASCII character the buffer holds nothing (not even the earlier ASCII).
    @Test func aNonAsciiCharacterClearsTheBufferAtOnce() {
        let h = harness()
        h.type(":ab")
        #expect(!h.matcher.holdsNoCharacters)
        _ = h.down(0, thai)
        #expect(h.matcher.holdsNoCharacters)
    }
}
