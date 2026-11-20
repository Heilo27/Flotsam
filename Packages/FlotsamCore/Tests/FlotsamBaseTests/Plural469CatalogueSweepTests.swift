import Foundation
import Testing
@testable import FlotsamBase

// TASK-469 / FR-000-05: the plural variations in Localizable.xcstrings are complete, resolve for n = 0, 1, 2 and more
// on the compiled path and on the raw-xcstrings fallback, and the fallback never lets a format specifier reach the user.

@Suite struct Plural469CatalogueSweepTests {
    private static let counts = [0, 1, 2, 5, 1000]

    private static func shippedEntries() throws -> [String: FlotsamCatalogue.Entry] {
        try FlotsamCatalogue.englishEntries().get()
    }

    private static func pluralEntries() throws -> [String: FlotsamCatalogue.Entry] {
        try shippedEntries().filter { $0.value.base.contains("%#@") }
    }

    /// Arguments for a resolved template: `count` in every integer slot, a label in every text slot.
    private static func arguments(for template: String, count: Int) -> [CVarArg] {
        (FlotsamStrings.formatKinds(in: template) ?? []).map { $0 == .integer ? (count as CVarArg) : ("label" as CVarArg) }
    }

    @Test("FR-000-05 the sweep finds the eight count strings that carry plural variations")
    func theExpectedKeysArePlural() throws {
        let expected: Set<String> = [
            "ui.library.footerItems", "ui.organize.confirmDelete", "ui.organize.confirmDeleteTag", "ui.row.bundleCount",
            "ui.settings.clearCount", "ui.settings.clearDone", "ui.settings.confirmBudget", "ui.settings.confirmShorten",
        ]
        #expect(Set(try Self.pluralEntries().keys) == expected)
    }

    @Test("FR-000-05 every plural slot names a substitution with a one and an other form that both carry the count")
    func substitutionsAreComplete() throws {
        for (key, entry) in try Self.pluralEntries() {
            var rest = Substring(entry.base)
            var slots = 0
            while let start = rest.range(of: "%#@") {
                let afterMarker = rest[start.upperBound...]
                let close = try #require(afterMarker.firstIndex(of: "@"), "\(key): unterminated plural slot")
                let name = String(afterMarker[..<close])
                let substitution = try #require(entry.substitutions[name], "\(key): slot \(name) has no one/other substitution")
                #expect(substitution.argNum >= 1, "\(key): argNum")
                #expect(substitution.one.contains("%arg"), "\(key): one form lacks %arg")
                #expect(substitution.other.contains("%arg"), "\(key): other form lacks %arg")
                #expect(substitution.one != substitution.other, "\(key): one and other are identical")
                slots += 1
                rest = afterMarker[afterMarker.index(after: close)...]
            }
            #expect(slots == entry.substitutions.count, "\(key): a substitution is declared but never used")
        }
    }

    @Test("FR-000-05 no count string outside the plural set puts a count in front of a noun")
    func noPluralisableCountIsLeftPlain() throws {
        // A "%lld" followed by a word is a count of something. Words that are not nouns are fine ("5 more", "3 selected",
        // "2 of 5", "3 queued"). Two nouns are left plain because their count can never be 1: CAP-LIM-003 only ever reports a
        // copy trimmed to the first 500, and ui.queue.ready only shows for a queue of two or more (PasteQueue.start refuses
        // fewer, FR-003-25).
        let notNouns: Set<String> = ["of", "more", "selected", "queued"]
        let exempt: Set<String> = ["error.CAP-LIM-003", "ui.queue.ready"]
        let regex = try Regex(#"%lld\s+([A-Za-z]+)"#)
        for (key, entry) in try Self.shippedEntries() where !entry.base.contains("%#@") && !exempt.contains(key) {
            for match in entry.base.matches(of: regex) {
                let word = match.output[1].substring.map(String.init)?.lowercased() ?? ""
                #expect(notNouns.contains(word), "\(key): '\(entry.base)' counts '\(word)' without plural variations")
            }
        }
    }

    @Test("FR-000-05 the compiled path renders every plural key with no specifier left over and 'one' only at exactly 1")
    func compiledPathNeverLeaks() throws {
        for (key, entry) in try Self.pluralEntries() {
            let template = try #require(FlotsamStrings.text(forKey: key), "\(key) is missing")
            #expect(FlotsamStrings.formatKinds(in: template) != nil, "\(key): template kinds unreadable: \(template)")
            for count in Self.counts {
                let text = try #require(FlotsamStrings.formatted(forKey: key, Self.arguments(for: template, count: count)))
                #expect(!text.contains("%") && !text.contains("#@"), "\(key) n=\(count) leaked a specifier: \(text)")
                let slot = try #require(entry.substitutions.values.first)
                let oneForm = slot.one.replacingOccurrences(of: "%arg", with: "\(count)")
                // "1 item" is also the start of "1 items", so the one form must not run on into more letters.
                let oneRegex = try Regex(NSRegularExpression.escapedPattern(for: oneForm) + "(?![A-Za-z])")
                #expect(text.contains(oneRegex) == (count == 1), "\(key) n=\(count): \(text)")
            }
        }
    }

    @Test("FR-000-05 the raw-xcstrings fallback renders every plural key with no specifier left over, and agrees with the compiled path")
    func rawFallbackNeverLeaksAndAgreesWithCompiled() throws {
        for (key, entry) in try Self.pluralEntries() {
            let compiledTemplate = try #require(FlotsamStrings.text(forKey: key))
            for count in Self.counts {
                // The same arguments feed both paths: the compiled template says which position holds the count.
                let arguments = Self.arguments(for: compiledTemplate, count: count)
                let resolved = FlotsamStrings.resolvingPlurals(in: entry, arguments: arguments)
                #expect(!resolved.contains("#@"), "\(key) n=\(count): plural slot left in \(resolved)")
                let raw = String(format: resolved, arguments: arguments)
                #expect(!raw.contains("%") && !raw.contains("#@"), "\(key) n=\(count) leaked a specifier: \(raw)")
                let compiled = try #require(FlotsamStrings.formatted(forKey: key, arguments))
                #expect(raw == compiled, "\(key) n=\(count): raw '\(raw)' vs compiled '\(compiled)'")
            }
        }
    }

    @Test("FR-000-05 given a catalogue with one plural key, when the fallback resolves it, then 1 takes 'one', every other count takes 'other', and a bad slot never leaks")
    func resolvingPluralsOnAHandBuiltCatalogue() throws {
        let json = """
        {"sourceLanguage":"en","strings":{
          "k.one":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"Remove %#@things@ now"},
            "substitutions":{"things":{"argNum":1,"formatSpecifier":"lld","variations":{"plural":{
              "one":{"stringUnit":{"state":"translated","value":"%arg thing"}},
              "other":{"stringUnit":{"state":"translated","value":"%arg things"}}}}}}}}},
          "k.orphan":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"Remove %#@gone@ now"}}}},
          "k.half":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"Remove %#@half@ now"},
            "substitutions":{"half":{"argNum":1,"formatSpecifier":"lld","variations":{"plural":{
              "one":{"stringUnit":{"state":"translated","value":"%arg half"}}}}}}}}}
        }}
        """
        let entries = try FlotsamCatalogue.englishEntries(from: Data(json.utf8)).get()
        let thing = try #require(entries["k.one"])
        #expect(thing.substitutions["things"]?.argNum == 1)
        func render(_ entry: FlotsamCatalogue.Entry, _ arguments: [CVarArg]) -> String {
            String(format: FlotsamStrings.resolvingPlurals(in: entry, arguments: arguments), arguments: arguments)
        }
        #expect(render(thing, [1]) == "Remove 1 thing now")
        #expect(render(thing, [0]) == "Remove 0 things now")
        #expect(render(thing, [2]) == "Remove 2 things now")
        // A count the slot cannot read, or no count at all, takes 'other' rather than leaking the slot.
        #expect(FlotsamStrings.resolvingPlurals(in: thing, arguments: ["text"]) == "Remove %1$lld things now")
        #expect(FlotsamStrings.resolvingPlurals(in: thing, arguments: []) == "Remove %1$lld things now")
        // A slot with no substitution is dropped; a substitution missing 'other' is not read at all.
        let orphan = try #require(entries["k.orphan"])
        #expect(FlotsamStrings.resolvingPlurals(in: orphan, arguments: [1]) == "Remove  now")
        let half = try #require(entries["k.half"])
        #expect(half.substitutions.isEmpty)
        #expect(!FlotsamStrings.resolvingPlurals(in: half, arguments: [1]).contains("#@"))
    }

    @Test("FR-000-05 formatKinds reads plural and positional slots in argument order and rejects gaps, repeats and other specifiers",
          arguments: [
            ("%#@items@", [MessageArgumentKind.integer]),
            ("%1$#@items@ older than %2$@", [.integer, .text]),
            ("Remove '%1$@' from %2$#@items@", [.text, .integer]),
            ("%2$@ then %1$lld", [.integer, .text]),
            ("100%% of %lld", [.integer]),
            ("plain", []),
          ])
    func formatKindsAccepts(template: String, kinds: [MessageArgumentKind]) {
        #expect(FlotsamStrings.formatKinds(in: template) == kinds)
    }

    @Test("FR-000-05 formatKinds returns nil for a skipped position, a repeated position, %d and a trailing percent",
          arguments: ["%2$@", "%1$@ %1$lld", "%d", "%1$d", "50%", "%#@items"])
    func formatKindsRejects(template: String) {
        #expect(FlotsamStrings.formatKinds(in: template) == nil)
    }
}
