import Foundation
import Testing
import FlotsamBase
import FlotsamStorage
@testable import FlotsamPaste

/// FR-005-17 / AC-005-16.
@Suite struct TemplateVariablesTests {
    /// 2026-11-16 14:05 UTC, en_US.
    private func context(clipboard: String = "") -> TemplateContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 14, minute: 5)) ?? .now
        return TemplateContext(now: now, calendar: calendar, locale: Locale(identifier: "en_US"), clipboardText: clipboard)
    }

    private func expand(_ text: String, clipboard: String = "") -> String {
        TemplateVariables.expand(text, context: context(clipboard: clipboard))
    }

    @Test func dateAndTimeUseTheLocaleStyles() {
        #expect(expand("{date}") == "Nov 16, 2026")
        #expect(expand("{time}").hasPrefix("2:05"))
        #expect(expand("{time}").hasSuffix("PM"))
    }

    @Test func formatsTakeUnicodePatterns() {
        #expect(expand("{date:yyyy-MM-dd}") == "2026-11-16")
        #expect(expand("{time:HH:mm}") == "14:05")
        #expect(expand("on {date:EEE, d MMM} at {time:H.mm}!") == "on Mon, 16 Nov at 14.05!")
    }

    @Test func clipboardIsInsertedAndNotExpandedAgain() {
        #expect(expand("[{clipboard}]", clipboard: "abc") == "[abc]")
        #expect(expand("[{clipboard}]") == "[]")
        #expect(expand("{clipboard}", clipboard: "{date} {{date}} {clipboard}") == "{date} {{date}} {clipboard}")
    }

    @Test func unknownNamesAndBadFormatsStayLiteral() {
        for text in ["{foo}", "{date:@@}", "{date:}", "{clipboard:x}", "{Date}", "{date:" + String(repeating: "y", count: 33) + "}"] {
            #expect(expand(text) == text, "\(text)")
        }
    }

    @Test func doubledBracesAroundAKnownNameEscape() {
        #expect(expand("{{date}}") == "{date}")
        #expect(expand("{{date:yyyy}} {{clipboard}}") == "{date:yyyy} {clipboard}")
        #expect(expand("{{ .Name }}") == "{{ .Name }}")
        #expect(expand("{{foo}}") == "{{foo}}")
        #expect(expand("{{{{ x }}}}") == "{{{{ x }}}}")
    }

    @Test func strayBraceBeforeAVariableStaysLiteral() {
        #expect(expand("{{date}") == "{Nov 16, 2026")
        #expect(expand("{date}}") == "Nov 16, 2026}")
        #expect(expand("{\"a\": 1}") == "{\"a\": 1}")
        #expect(expand("{") == "{")
        #expect(expand("{date") == "{date")
    }

    @Test func textWithoutVariablesIsReturnedAsIs() {
        #expect(expand("hello, world é 🇫🇷") == "hello, world é 🇫🇷")
        #expect(TemplateVariables.hasSubstitutions(in: "plain") == false)
        #expect(TemplateVariables.hasSubstitutions(in: "{foo}") == false)
        #expect(TemplateVariables.hasSubstitutions(in: "{{date}}"))
        #expect(TemplateVariables.hasSubstitutions(in: "a {time}"))
    }

    @Test func saveTimeWarnsOnUnknownVariablesOnly() {
        func code(_ text: String) -> ErrorCode? {
            if case .failure(let error) = TemplateVariables.validate(text) { return error.code }
            return nil
        }
        #expect(code("{foo}") == .trgVal005)
        #expect(code("{date:@@}") == .trgVal005)
        #expect(code("{date} {time:HH} {clipboard} {{date}} {{ .Name }} {{foo}} {\"a\":1}") == nil)
    }

    @Test func expansionIsTruncatedAtTheTextCeiling() {
        let big = String(repeating: "é", count: IngestLimits.maxTextBytes / 2 + 10)
        let result = expand("{clipboard}", clipboard: big)
        #expect(result.utf8.count <= IngestLimits.maxTextBytes)
        #expect(result.utf8.count >= IngestLimits.maxTextBytes - 1)
        #expect(result.allSatisfy { $0 == "é" })
    }
}
