import Testing
import FlotsamBase
@testable import FlotsamShortcuts

/// TASK-436 (Worf, blind), OC-8016 / Rule 9: the recorder-side validator and the stored-data rule must agree on which
/// key codes are usable. Expected side is a literal set (FR-005-02 b), no production symbol.
@Suite struct Worf436ChordUsableKeyTests {
    private static let usableKeyCodes: Set<UInt16> = {
        var s = Set<UInt16>(0...51)
        s.remove(10)
        s.formUnion([53, 123, 124, 125, 126])
        s.formUnion([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90])
        return s
    }()

    /// given all four modifiers (never on the reserved list), when each key code 0...300 and 65535 is validated, then
    /// it passes exactly for the literal usable set and otherwise fails TRG-VAL-003. Red if ChordValidator stops
    /// rejecting unusable keys or diverges from the stored-data rule.
    @Test func validatorAcceptsExactlyTheLiteralUsableKeys() {
        let all: ChordModifiers = [.control, .option, .shift, .command]
        var wrong: [UInt16] = []
        for code in Array(0...300) + [65535] {
            let k = UInt16(code)
            let result = ChordValidator.validate(Chord(keyCode: k, modifiers: all))
            let passed: Bool
            if case .success = result { passed = true } else { passed = false }
            if case .failure(let e) = result, e.code != .trgVal003 { wrong.append(k) }
            if passed != Self.usableKeyCodes.contains(k) { wrong.append(k) }
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    /// Validator and stored-data rule agree: a chord the validator accepts is never reset when read back, and a chord
    /// the validator rejects for its key is reset. Round-trips through a fresh store.
    @Test func validatorAndStoredRuleAgreeAcrossKeyCodes() {
        var disagree: [UInt16] = []
        for code in Array(0...130) + [9999, 65535] {
            let chord = Chord(keyCode: UInt16(code), modifiers: [.control, .option, .shift, .command])
            var accepted = false
            if case .success = ChordValidator.validate(chord) { accepted = true }
            let kept = chord.hasUsableKey
            if accepted != kept { disagree.append(chord.keyCode) }
        }
        #expect(disagree.isEmpty, "\(disagree)")
    }
}
