import Foundation
import Testing
import FlotsamBase
@testable import FlotsamTriggers

// FRD-005 8T contract tests, slice S5 (trigger grammar: FR-005-08 and AC-005-07, OC-5043..OC-5053), written from the
// blind oracle contract (.claude/oracle/frd-005-contract.json). Inputs and expected codes/messages are literals.
//
// Layering: `TriggerGrammar.validate(_:among:)` is the one verdict the editor consults. "Accepted" is a success verdict;
// "rejected, not saved" is the failure verdict with its code and its catalogue text (`FlotsamStrings.message(for:)`,
// the text the inline error under the field shows). The save button gate (`ItemBindingsEditorModel.canSave`) and the
// trigger badge (`ItemRow.hasTrigger` after the editor writes the binding) live in the App target, which the package
// cannot import; that half of "saved" / "badge shown" is App-layer and is not faked here. Where the contract says "not
// saved" the package-level obligation is that the verdict is a failure carrying the right code, and the editor's
// `canSave` is exactly `triggerErrorMessage == nil`, which is derived from this same verdict.
// Analogue that stays as it is: TriggerGrammarTests.

private let messageTRGVAL001 = "Triggers start with a symbol (like ;), have 2 to 24 characters and contain no spaces."
private let messageTRGVAL002 = "That trigger is already used by another item."

private struct Verdict: Equatable {
    let code: String?
    let message: String?

    static let accepted = Verdict(code: nil, message: nil)
    static let tooBadShape = Verdict(code: "TRG-VAL-001", message: messageTRGVAL001)
    static let duplicate = Verdict(code: "TRG-VAL-002", message: messageTRGVAL002)
}

private func verdict(_ text: String, among others: [String] = []) -> Verdict {
    switch TriggerGrammar.validate(text, among: others) {
    case .success: .accepted
    case .failure(let error): Verdict(code: error.code.rawValue, message: FlotsamStrings.message(for: error))
    }
}

@Suite("FRD-005 contract: trigger grammar (S5)")
struct FRD005ContractTestsGrammar {
    @Test("OC-5043 ';sig' is accepted for an item with no trigger, and other items' triggers do not block it")
    func oc5043SigIsAccepted() {
        // given a text item with no trigger (the editor passes every OTHER item's trigger as `existing`)
        // when the user saves ';sig'
        // then it is accepted, alone and next to other triggers; a near neighbour ';sigs' does not collide with it
        #expect(verdict(";sig") == .accepted)
        #expect(verdict(";sig", among: [";other", "!mail"]) == .accepted)
        #expect(verdict(";sig", among: [";sigs"]) == .accepted)
    }

    @Test("OC-5044 ';Sig' on a second item is TRG-VAL-002 with the catalogue text, while ';sig' is held by another item")
    func oc5044DuplicateIsCaseInsensitive() {
        // given another item has ';sig'
        // when the user saves ';Sig' on a second item
        // then TRG-VAL-002 with 'That trigger is already used by another item.'
        #expect(verdict(";Sig", among: [";sig"]) == .duplicate)
        #expect(verdict(";SIG", among: [";other", ";sig"]) == .duplicate)
        // and editing the item that owns ';sig' keeps it valid (its own trigger is not passed in `existing`)
        #expect(verdict(";sig", among: [";other"]) == .accepted)
    }

    @Test("OC-5045 'sig' (no leading symbol) is TRG-VAL-001 with the catalogue text")
    func oc5045MissingSymbol() {
        // given the trigger field, when the user enters 'sig', then TRG-VAL-001 with the inline text; not saved
        #expect(verdict("sig") == .tooBadShape)
    }

    @Test("OC-5046 ';' alone is TRG-VAL-001, while ';s' (two characters) is the smallest accepted trigger")
    func oc5046SymbolAlone() {
        // given the trigger field, when the user enters ';' alone, then TRG-VAL-001; not saved
        #expect(verdict(";").code == "TRG-VAL-001")
        // boundary: one character more is accepted
        #expect(verdict(";s") == .accepted)
    }

    @Test("OC-5047 '; sig' (a space inside) is TRG-VAL-001")
    func oc5047SpaceInside() {
        // given the trigger field, when the user enters '; sig', then TRG-VAL-001; not saved
        #expect(verdict("; sig").code == "TRG-VAL-001")
        // and a trailing or leading space is no better
        #expect(verdict(";sig ").code == "TRG-VAL-001")
        #expect(verdict(" ;sig").code == "TRG-VAL-001")
    }

    @Test("OC-5048 ';é' (a non-ASCII letter) is TRG-VAL-001, as is a letter made of a combining sequence")
    func oc5048NonAsciiLetter() {
        // given the trigger field, when the user enters ';é', then TRG-VAL-001; not saved
        #expect(verdict(";\u{00E9}").code == "TRG-VAL-001")
        #expect(verdict(";e\u{0301}").code == "TRG-VAL-001")
    }

    @Test("OC-5049 ';' plus 23 letters (24 characters) is accepted")
    func oc5049UpperBoundIsAccepted() {
        // given the trigger field, when the user enters ';' followed by 23 letters (24 characters)
        let text = ";" + String(repeating: "a", count: 23)
        #expect(text.count == 24)
        // then it is accepted and saved
        #expect(verdict(text) == .accepted)
    }

    @Test("OC-5050 ';' plus 24 letters (25 characters) is TRG-VAL-001")
    func oc5050OverUpperBound() {
        // given the trigger field, when the user enters ';' followed by 24 letters (25 characters)
        let text = ";" + String(repeating: "a", count: 24)
        #expect(text.count == 25)
        // then TRG-VAL-001; not saved. The 24-character neighbour (OC-5049) is the accepted side of this boundary.
        #expect(verdict(text) == .tooBadShape)
        #expect(verdict(";" + String(repeating: "a", count: 23)) == .accepted)
    }

    @Test("OC-5051 '1abc', 'abc', ';a.b', a full-width semicolon and a tab are each TRG-VAL-001")
    func oc5051MalformedShapes() {
        // given the trigger field, when the user enters each of these in turn
        let inputs = ["1abc", "abc", ";a.b", "\u{FF1B}sig", ";ab\t"]
        // then each is rejected with TRG-VAL-001 (and the catalogue text)
        for input in inputs {
            #expect(verdict(input) == .tooBadShape, "\(input.debugDescription)")
        }
        #expect(inputs.count == 5)
    }

    @Test("OC-5052 every permitted ASCII punctuation range may lead a trigger; letters, digits, space and DEL may not")
    func oc5052LeadingSymbolRanges() {
        // given the trigger field on separate items
        // when the user enters the contract's eight triggers
        let contractInputs = [";a-b_9", "!x", "/x", "@x", "[x", "`x", "{x", "~x"]
        // then each is accepted
        for input in contractInputs {
            #expect(verdict(input) == .accepted, "\(input.debugDescription)")
        }
        // and every one of the 32 ASCII punctuation characters (the four ranges) leads a valid trigger
        let punctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
        #expect(punctuation.count == 32)
        for lead in punctuation {
            #expect(verdict("\(lead)x") == .accepted, "\(lead)")
        }
        // while a letter, a digit, a space or DEL in the lead position is rejected
        for lead in ["a", "Z", "0", "9", " ", "\u{7F}"] {
            #expect(verdict("\(lead)x") == .tooBadShape, "\(lead.debugDescription)")
        }
    }

    @Test("OC-5053 ';s' on one item and ';sig' on another are both accepted")
    func oc5053PrefixesCoexist() {
        // given item S and item G
        // when the user saves ';s' on S (G already holds ';sig') and ';sig' on G (S already holds ';s')
        // then both are accepted: a trigger that is a prefix of another is not a duplicate
        #expect(verdict(";s", among: [";sig"]) == .accepted)
        #expect(verdict(";sig", among: [";s"]) == .accepted)
        #expect(verdict(";s", among: [";s"]) == .duplicate)
    }
}
