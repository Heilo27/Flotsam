import Foundation
import Testing
@testable import FlotsamBase

/// TASK-374: tests that kill the FRD-000 Strings mutants that survived the TASK-369 census. Every expected value is a
/// literal; none is computed with a production symbol. Each test names the mutant it turns red (census ids X0nn).
@Suite("TASK-374 Strings survivors (FR-000-05, FR-000-06, FR-000-07)", .timeLimit(.minutes(1)))
struct StringsSurvivorTests {

    // MARK: Catalogue reader error context (OC-0020, OC-0021). Kills X014, X017, X019.

    private func internalText(_ error: FlotsamError) -> String { "\(error.internalMessage)" }

    /// given a catalogue path that does not exist, when read, then SYS-INT-001 with the exact developer text.
    /// Mutation X014 (text gains "~") turns this red.
    @Test("OC-0021 an unreadable catalogue file reports 'catalogue file unreadable'")
    func unreadableFileContext() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-\(UUID().uuidString).xcstrings")
        guard case .failure(let error) = FlotsamCatalogue.englishStrings(at: missing) else {
            Issue.record("a missing file must fail")
            return
        }
        #expect(error.code == .sysInt001)
        #expect(internalText(error) == "catalogue file unreadable")
        #expect(error.underlying != nil)
    }

    /// given bytes that are not JSON, when read, then the developer text names the JSON failure.
    /// Mutation X017 turns this red. Also separates it from the no-table text (a swap of the two would go red).
    @Test("OC-0021 non-JSON bytes report 'catalogue is not JSON'")
    func notJSONContext() {
        guard case .failure(let error) = FlotsamCatalogue.englishStrings(from: Data("not json at all".utf8)) else {
            Issue.record("non-JSON must fail")
            return
        }
        #expect(error.code == .sysInt001)
        #expect(internalText(error) == "catalogue is not JSON")
        #expect(error.underlying != nil)
    }

    /// given valid JSON with no `strings` table, or a `strings` value of the wrong type, then the text says so and
    /// there is no underlying error (nothing threw). Mutation X019 turns this red.
    @Test("OC-0021 JSON without a strings table reports 'catalogue has no strings table'",
          arguments: ["{\"sourceLanguage\":\"en\"}", "[]", "{\"strings\":[1,2]}"])
    func noTableContext(text: String) {
        guard case .failure(let error) = FlotsamCatalogue.englishStrings(from: Data(text.utf8)) else {
            Issue.record("table-less JSON must fail: \(text)")
            return
        }
        #expect(error.code == .sysInt001)
        #expect(internalText(error) == "catalogue has no strings table")
        #expect(error.underlying == nil)
    }

    // MARK: Placeholder parser (OC-0018). Kills X043, X053, X054, X058, X059.

    /// given templates mixing `%@` and `%lld` in each order, when parsed, then the kinds come back in template order.
    /// Mutation X043 (lastIndex of "%") returns only the last placeholder and turns this red.
    @Test("OC-0018 placeholders are read in template order, mixed kinds",
          arguments: [
            ("Sent %@ then %lld files", [MessageArgumentKind.text, .integer]),
            ("Sent %lld then %@ files", [MessageArgumentKind.integer, .text]),
            ("%@ %@ %lld", [MessageArgumentKind.text, .text, .integer]),
            ("no placeholders at all", []),
          ])
    func kindsInOrder(template: String, expected: [MessageArgumentKind]) {
        #expect(FlotsamStrings.placeholderKinds(in: template) == expected)
    }

    /// given `%%` followed by what looks like a specifier, when parsed, then the pair is one literal percent and the
    /// next characters are plain text. Mutations X053 (dropLast) and X054 (statement deleted) turn this red.
    @Test("OC-0018 a doubled percent is a literal and consumes both characters",
          arguments: [
            ("100%%@", []),
            ("100%%lld", []),
            ("%%%@", [MessageArgumentKind.text]),
            ("100%% of %lld", [MessageArgumentKind.integer]),
          ])
    func doublePercentIsLiteral(template: String, expected: [MessageArgumentKind]) {
        #expect(FlotsamStrings.placeholderKinds(in: template) == expected)
    }

    /// given `%lld` directly followed by another specifier, when parsed, then exactly three characters are consumed
    /// and the next placeholder is read. Mutation X059 (dropFirst(4)) swallows the `%` and turns this red; X058
    /// (dropLast(3)) turns the `%lld of %@` case red.
    @Test("OC-0018 %lld consumes exactly three characters",
          arguments: [
            ("%lld%@", [MessageArgumentKind.integer, .text]),
            ("%lld%lld", [MessageArgumentKind.integer, .integer]),
            ("%lld of %@", [MessageArgumentKind.integer, .text]),
          ])
    func lldConsumesThree(template: String, expected: [MessageArgumentKind]) {
        #expect(FlotsamStrings.placeholderKinds(in: template) == expected)
    }

    /// Unsupported specifiers return nil (the whole template is refused), including a trailing `%`.
    @Test("OC-0018 unsupported specifiers and a trailing percent refuse the template",
          arguments: ["%d", "%1$@", "%f", "50%", "%lld and %d", "%lli"])
    func unsupportedSpecifiersAreNil(template: String) {
        #expect(FlotsamStrings.placeholderKinds(in: template) == nil)
    }

    // MARK: Name truncation boundaries (OC-0015, OC-0018). Kills X036, X068, X069, X070.

    /// CAP-LIM-001 renders as 68 characters plus the app name, so the name budget is 72 characters.
    /// given names of 71, 72 and 73 characters, then 71 and 72 pass through whole and 73 (excess exactly 1) is cut
    /// to 71 characters plus "…", landing on exactly 140. Mutation X036 (excess <= 1 returns early) leaves the
    /// 73-character name uncut at 141 and turns this red.
    @Test("OC-0015 name budget boundary: 72 fits, 73 (excess 1) is cut to 140 characters")
    func nameBoundaryExcessOne() {
        let tail = "). It is still on your clipboard."
        let head = "A copy was too large to save (over "
        let at71 = FlotsamStrings.message(for: .capLim001, arguments: [.appName(String(repeating: "A", count: 71))])
        let at72 = FlotsamStrings.message(for: .capLim001, arguments: [.appName(String(repeating: "A", count: 72))])
        let at73 = FlotsamStrings.message(for: .capLim001, arguments: [.appName(String(repeating: "A", count: 73))])
        #expect(at71 == head + String(repeating: "A", count: 71) + tail)
        #expect(at71.count == 139)
        #expect(at72 == head + String(repeating: "A", count: 72) + tail)
        #expect(at72.count == 140)
        #expect(at73 == head + String(repeating: "A", count: 71) + "\u{2026}" + tail)
        #expect(at73.count == 140)
    }

    /// given a name longer than the limit, when formatted, then the first limit-1 characters and "…" come back.
    /// Mutation X068 (prefix(limit+1)) and X069 (suffix) turn this red. Observed at `formatArgument` because the
    /// message loop re-cuts an over-long result and hides these two from any `message(for:)` assertion.
    @Test("OC-0015 a cut name keeps its leading characters and ends with an ellipsis")
    func cutNameKeepsLeadingCharacters() {
        let cut = MessageArgument.appName("ABCDEFGHIJ").formatArgument(appNameLimit: 5)
        #expect(cut as? String == "ABCD\u{2026}")
        #expect(MessageArgument.appName("ABCDEFGHIJ").formatArgument(appNameLimit: 9) as? String == "ABCDEFGH\u{2026}")
    }

    /// given a name exactly at the limit, then it is untouched; one over, it is cut. Pins the `>` comparison.
    @Test("OC-0015 a name exactly at the limit is returned whole")
    func nameAtLimitIsWhole() {
        #expect(MessageArgument.appName("ABCDE").formatArgument(appNameLimit: 5) as? String == "ABCDE")
        #expect(MessageArgument.appName("ABCDEF").formatArgument(appNameLimit: 5) as? String == "ABCD\u{2026}")
        #expect(MessageArgument.appName("ABCDEF").formatArgument() as? String == "ABCDEF")
    }

    /// given a limit of 1 or 0, then only the ellipsis remains, never a leading character plus an ellipsis.
    /// Mutation X070 (max(1, limit-1)) keeps one character at limit 1 and 0 and turns this red.
    @Test("OC-0015 limits of 1 and 0 leave only the ellipsis")
    func tinyLimitsLeaveOnlyEllipsis() {
        #expect(MessageArgument.appName("ABCDEF").formatArgument(appNameLimit: 1) as? String == "\u{2026}")
        #expect(MessageArgument.appName("ABCDEF").formatArgument(appNameLimit: 0) as? String == "\u{2026}")
        #expect(MessageArgument.appName("ABCDEF").formatArgument(appNameLimit: 2) as? String == "A\u{2026}")
    }

    /// An empty and a multi-scalar name at the boundary: truncation counts characters, not scalars or bytes.
    @Test("OC-0015 truncation counts characters: an emoji name is cut on a character boundary")
    func characterBoundary() {
        let name = String(repeating: "🙂", count: 80)
        let message = FlotsamStrings.message(for: .capLim001, arguments: [.appName(name)])
        #expect(message == "A copy was too large to save (over " + String(repeating: "🙂", count: 71) + "\u{2026}). It is still on your clipboard.")
        #expect(FlotsamStrings.message(for: .capLim001, arguments: [.appName("")]) == "A copy was too large to save (over ). It is still on your clipboard.")
    }
}
