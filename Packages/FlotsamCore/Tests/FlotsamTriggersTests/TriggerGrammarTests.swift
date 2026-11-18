import Testing
import FlotsamBase
@testable import FlotsamTriggers

/// FR-005-08 / AC-005-07.
@Suite struct TriggerGrammarTests {
    private func code(_ result: FlotsamResult<Void>) -> ErrorCode? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    @Test func acceptsSymbolThenWord() {
        for text in [";sig", ";Sig", ";s", "/a-b_c9", "!x", "~a", "@home", "{x", "`q"] {
            #expect(code(TriggerGrammar.validate(text)) == nil, "\(text)")
        }
    }

    @Test func rejectsMalformedTriggers() {
        for text in ["sig", ";", "", "; sig", ";é", ";sig!", ";a.b", "1sig", "~~", ";sig\n", " ;sig", ";e\u{301}"] {
            #expect(code(TriggerGrammar.validate(text)) == .trgVal001, "\(text.debugDescription)")
        }
    }

    @Test func lengthBoundaryIs24Characters() {
        #expect(code(TriggerGrammar.validate(";" + String(repeating: "a", count: 23))) == nil)
        #expect(code(TriggerGrammar.validate(";" + String(repeating: "a", count: 24))) == .trgVal001)
    }

    @Test func duplicatesAreCaseInsensitive() {
        #expect(code(TriggerGrammar.validate(";Sig", among: [";sig", ";other"])) == .trgVal002)
        #expect(code(TriggerGrammar.validate(";sigs", among: [";sig"])) == nil)
        #expect(code(TriggerGrammar.validate(";s", among: [";sig"])) == nil)
    }

    @Test func malformedWinsOverDuplicate() {
        #expect(code(TriggerGrammar.validate("sig", among: ["sig"])) == .trgVal001)
    }

    @Test func canonicalKeyFoldsAsciiOnly() {
        #expect(TriggerGrammar.canonicalKey(";SiG-9_") == ";sig-9_")
        // The Kelvin sign must not fold to "k": SQLite NOCASE does not fold it either.
        #expect(TriggerGrammar.canonicalKey(";\u{212A}") == ";\u{212A}")
    }
}
