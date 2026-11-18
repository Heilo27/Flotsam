import FlotsamBase
import Foundation
import Testing
@testable import FlotsamPaste

// Worf, TASK-395 (FR-005-17, AC-005-16, OC-5058), blind. Expected strings are literals copied from the FRD-000
// section 8 catalogue wording; no production string symbol is used on the expected side.
// Mutation that must turn these red: re-add `context: [.count: .int(n)]` to the TRG-VAL-005 error in
// TemplateVariables.validate (the text then falls back to the SYS-INT-001 sentence).

private let unknownVariableText = "An unknown variable was left as plain text."
private let genericFallbackText =
    "Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings \u{203A} About."

@Suite struct Worf395UnknownVariableTextTests {
    private func failure(_ text: String) -> FlotsamError? {
        if case .failure(let error) = TemplateVariables.validate(text) { return error }
        return nil
    }

    private func message(_ text: String) -> String? { failure(text).map { FlotsamStrings.message(for: $0) } }

    // OC-5058. given one unknown variable, when validated, then the catalogue text (not SYS-INT-001) is the message.
    @Test func oneUnknownVariableReadsTheCatalogueText() {
        #expect(message("Hi {foo}") == "An unknown variable was left as plain text.")
        #expect(message("Hi {foo}") != genericFallbackText)
    }

    // given several unknowns (including a bad format), then the same single sentence; no count leaks in.
    @Test func severalUnknownVariablesReadTheSameSentence() {
        for text in ["{foo} {bar}", "A {foo} B {date:@@}", "{a}{b}{c}{d}{e}", "{date:@@} {clipboard:x} {nope}"] {
            #expect(message(text) == "An unknown variable was left as plain text.", "text: \(text)")
            #expect(failure(text)?.code == .trgVal005, "text: \(text)")
        }
    }

    // given known and unknown mixed, then the warning appears (unknown present) with the catalogue text.
    @Test func mixOfKnownAndUnknownWarns() {
        #expect(message("{date} then {foo} then {clipboard}") == "An unknown variable was left as plain text.")
        #expect(message("{{date}} {foo}") == "An unknown variable was left as plain text.")
    }

    // given no unknown variables, then validate succeeds: no warning at all (negative / empty / boundary).
    @Test func noUnknownVariablesProduceNoWarning() {
        let clean = [
            "", "plain", "{date}", "{time:HH:mm}", "{clipboard}", "{date} {time} {clipboard}", "{{date}}",
            "{{ .Name }}", "{{foo}}", "{\"a\":1}", "{", "}", "{}", "{date",
        ]
        for text in clean {
            #expect(failure(text) == nil, "text: \(text)")
            #expect(message(text) == nil, "text: \(text)")
        }
    }

    // Boundary: a 32-character format is valid (no warning), 33 is unknown (warning with the catalogue text).
    @Test func formatLengthBoundaryDecidesTheWarning() {
        let ok32 = "{date:" + String(repeating: "y", count: 32) + "}"
        let bad33 = "{date:" + String(repeating: "y", count: 33) + "}"
        #expect(message(ok32) == nil)
        #expect(message(bad33) == "An unknown variable was left as plain text.")
    }

    // No catalogue code reachable from validate falls back: over a spread of inputs every failure is TRG-VAL-005,
    // carries no context (the catalogue sentence has no placeholder), and renders neither empty nor the SYS-INT-001 text.
    @Test func noCodeReachableFromValidateFallsBackToSysInt001() {
        let inputs = [
            "{foo}", "{foo} {foo}", "{date:@@}", "{time:@}", "{clipboard:x}", "{Date}", "{date:}", "{a_b}",
            String(repeating: "{x}", count: 500), "é {zz} 🇫🇷", "{{{foo}}}", "x{foo", "{foo}\n{bar}",
        ]
        var reached: Set<ErrorCode> = []
        var failures = 0
        for text in inputs {
            guard let error = failure(text) else { continue }
            failures += 1
            reached.insert(error.code)
            #expect(error.context.isEmpty, "text: \(text.prefix(20))")
            let rendered = FlotsamStrings.message(for: error)
            #expect(rendered != genericFallbackText, "text: \(text.prefix(20))")
            #expect(rendered == "An unknown variable was left as plain text.", "text: \(text.prefix(20))")
        }
        #expect(failures >= 10)
        #expect(reached == [.trgVal005])
        #expect(FlotsamStrings.message(for: ErrorCode.trgVal005) == unknownVariableText)
        // The fallback literal above really is the SYS-INT-001 catalogue text (guards a stale literal).
        #expect(FlotsamStrings.message(for: ErrorCode.sysInt001) == genericFallbackText)
    }
}
