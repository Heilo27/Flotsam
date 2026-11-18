import Testing
import FlotsamBase
@testable import FlotsamShortcuts

/// FR-005-02 / AC-005-02: the binding rules.
@Suite struct ChordValidatorTests {
    private func code(_ result: FlotsamResult<Void>) -> ErrorCode? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    @Test func commandOrControlPlusLetterIsValid() {
        #expect(code(ChordValidator.validate(.cmdK)) == nil)
        #expect(code(ChordValidator.validate(Chord(keyCode: 40, modifiers: .control))) == nil)
        #expect(code(ChordValidator.validate(Chord(keyCode: 40, modifiers: [.command, .shift, .option]))) == nil)
    }

    @Test func missingCommandAndControlIsRejected() {
        for modifiers: ChordModifiers in [[], .option, .shift, [.option, .shift]] {
            #expect(code(ChordValidator.validate(Chord(keyCode: 40, modifiers: modifiers))) == .trgVal003)
        }
    }

    @Test func modifierKeysAndUnknownKeysAreRejected() {
        for key: UInt16 in [54, 55, 56, 58, 59, 63, 200] {
            #expect(code(ChordValidator.validate(Chord(keyCode: key, modifiers: .command))) == .trgVal003)
        }
    }

    @Test func namedKeysAndFunctionKeysAreValid() {
        for key: UInt16 in [49, 36, 48, 53, 51, 123, 126, 122, 90] {
            #expect(code(ChordValidator.validate(Chord(keyCode: key, modifiers: [.command, .shift]))) == nil)
        }
    }

    @Test func reservedChordsAreRejected() {
        let reserved: [Chord] = [
            Chord(keyCode: 12, modifiers: .command), Chord(keyCode: 13, modifiers: .command),
            Chord(keyCode: 4, modifiers: .command), Chord(keyCode: 46, modifiers: .command),
            Chord(keyCode: 48, modifiers: .command), Chord(keyCode: 49, modifiers: .command),
            Chord(keyCode: 49, modifiers: .control), Chord(keyCode: 53, modifiers: [.command, .option]),
            Chord(keyCode: 43, modifiers: .command),
        ] + [8, 9, 7, 6, 0].map { Chord(keyCode: $0, modifiers: .command) }
        for chord in reserved { #expect(code(ChordValidator.validate(chord)) == .trgVal003) }
    }

    @Test func reservedListIsExactModifierSet() {
        // ⌘⇧C and ⌃⌘V are not "⌘ plus C with no other modifier".
        #expect(code(ChordValidator.validate(Chord(keyCode: 8, modifiers: [.command, .shift]))) == nil)
        #expect(code(ChordValidator.validate(.ctrlCmdV)) == nil)
    }

    @Test func systemOwnedChordIsRejected() {
        #expect(code(ChordValidator.validate(.cmdK, systemChords: [.cmdK])) == .trgVal003)
        #expect(code(ChordValidator.validate(.cmdJ, systemChords: [.cmdK])) == nil)
    }
}
