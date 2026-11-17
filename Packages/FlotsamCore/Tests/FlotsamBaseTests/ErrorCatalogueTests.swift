import Foundation
import Testing
@testable import FlotsamBase

/// FR-000-07 / AC-000-02: the code enum and the catalogue must be identical sets. The catalogue is read through
/// `FlotsamCatalogue` (the production reader) and judged by `CatalogueConsistency`; the mutated-copy tests prove the
/// check goes red when the catalogue or the enum is wrong.
@Suite struct ErrorCatalogueTests {
    private typealias Check = CatalogueConsistency

    @Test func rawValuesAreUnique() {
        let raws = ErrorCode.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
    }

    @Test func rawValuesFollowCodeFormat() {
        for code in ErrorCode.allCases {
            let parts = code.rawValue.split(separator: "-")
            #expect(parts.count == 3 && parts[2].count == 3 && Int(parts[2]) != nil, "\(code.rawValue)")
        }
    }

    @Test func everyNonInfoCodeHasAMessageUnder140Characters() throws {
        let catalogue = try Repo.catalogue()
        for code in ErrorCode.allCases where code.severity != .info {
            let message = try #require(catalogue[code.catalogueKey], "\(code.rawValue) has no catalogue key")
            #expect(message.count <= 140, "\(code.rawValue) message is \(message.count) characters")
            #expect(FlotsamStrings.text(forKey: code.catalogueKey) == message)
        }
    }

    @Test func everyErrorCatalogueKeyHasACode() throws {
        let catalogue = try Repo.catalogue()
        let known = Set(ErrorCode.allCases.map(\.catalogueKey))
        for key in catalogue.keys where key.hasPrefix("error.") {
            #expect(known.contains(key), "\(key) has no ErrorCode")
        }
    }

    /// FRD-000 section 7 / FR-000-05. given SYS-INT-001, then its text is the verbatim section 7 text; given a code
    /// whose placeholders the caller did not fill, then the user sees that same text (the fallback), never a template.
    @Test("SYS-INT-001 text is verbatim and is the fallback for an unfilled template")
    func internalErrorTextIsVerbatimAndIsTheFallback() {
        let verbatim = "Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings › About."
        #expect(FlotsamStrings.text(forKey: "error.NOPE-XXX-999") == nil)
        #expect(FlotsamStrings.message(for: .sysInt001) == verbatim)
        #expect(FlotsamStrings.message(for: .capLim003) == verbatim, "CAP-LIM-003 needs a count; none given")
    }

    // MARK: OC-0021 consistency check against mutated catalogues

    /// OC-0021 baseline. given the shipped catalogue and enum read through the production reader, then the check finds
    /// nothing. This is the precondition that makes each red mutated case attributable to its mutation.
    @Test("OC-0021 the shipped catalogue and enum are consistent")
    func shippedCatalogueIsConsistent() throws {
        #expect(Check.violations(catalogue: try Repo.catalogue(), codes: Check.shippedCodes) == [])
    }

    /// OC-0021 (1). given error.SYS-INT-001 removed, then the check fails naming that key.
    @Test("OC-0021 (1) a removed key fails the check")
    func removedKeyFails() throws {
        let data = try Check.mutatedShippedData { $0["error.SYS-INT-001"] = nil }
        let catalogue = try FlotsamCatalogue.englishStrings(from: data).get()
        #expect(catalogue["error.SYS-INT-001"] == nil, "precondition: key is gone")
        #expect(Check.violations(catalogue: catalogue, codes: Check.shippedCodes) == ["missing:error.SYS-INT-001"])
    }

    /// OC-0021 (2). given a 141-character message on one code, then the check fails; given 140, it passes.
    @Test("OC-0021 (2) a 141-character message fails; 140 passes")
    func overlongMessageFails() throws {
        let tooLong = try Check.mutatedShippedData { $0["error.CAP-IO-001"] = Check.entry(String(repeating: "x", count: 141)) }
        let atLimit = try Check.mutatedShippedData { $0["error.CAP-IO-001"] = Check.entry(String(repeating: "x", count: 140)) }
        let longCatalogue = try FlotsamCatalogue.englishStrings(from: tooLong).get()
        let limitCatalogue = try FlotsamCatalogue.englishStrings(from: atLimit).get()
        #expect(longCatalogue["error.CAP-IO-001"]?.count == 141, "precondition: the mutation reached the reader")
        #expect(Check.violations(catalogue: longCatalogue, codes: Check.shippedCodes) == ["tooLong:error.CAP-IO-001"])
        #expect(Check.violations(catalogue: limitCatalogue, codes: Check.shippedCodes) == [])
    }

    /// OC-0021 (3). given a message added for Info code CAP-POL-001, then the check fails.
    @Test("OC-0021 (3) a message on an Info code fails the check")
    func infoMessageFails() throws {
        let data = try Check.mutatedShippedData { $0["error.CAP-POL-001"] = Check.entry("Skipped a concealed item.") }
        let catalogue = try FlotsamCatalogue.englishStrings(from: data).get()
        #expect(Check.violations(catalogue: catalogue, codes: Check.shippedCodes) == ["infoHasMessage:error.CAP-POL-001"])
    }

    /// OC-0021 (4). given an orphan key error.XXX-INT-999 with no code, then the check fails naming it.
    @Test("OC-0021 (4) an orphan error key fails the check")
    func orphanKeyFails() throws {
        let data = try Check.mutatedShippedData { $0["error.XXX-INT-999"] = Check.entry("Nobody raises this.") }
        let catalogue = try FlotsamCatalogue.englishStrings(from: data).get()
        #expect(Check.violations(catalogue: catalogue, codes: Check.shippedCodes) == ["orphan:error.XXX-INT-999"])
    }

    /// OC-0021 (5). given two cases sharing one raw value, then the check fails naming the raw value.
    @Test("OC-0021 (5) two codes sharing a raw value fail the check")
    func duplicateRawValueFails() throws {
        let doubled = Check.shippedCodes + [(raw: "CAP-IO-001", severity: .error)]
        #expect(Check.violations(catalogue: try Repo.catalogue(), codes: doubled) == ["duplicate:CAP-IO-001"])
    }

    /// OC-0021 (6), FR-000-05, TASK-347. given a template whose specifier disagrees with the argument kinds its code
    /// declares, then the check fails naming that key. Each row is a different way to drift: text slot turned into a
    /// count slot, count slot turned into a text slot, a placeholder added to a code that takes none, a placeholder
    /// dropped from one that takes one, an unsupported `%d` specifier.
    @Test(
        "OC-0021 (6) a template that disagrees with its code's argument kinds fails the check",
        arguments: [
            ("CAP-LIM-001", "Too large (over %lld).", "error.CAP-LIM-001"),
            ("CAP-LIM-003", "Trimmed %@ files.", "error.CAP-LIM-003"),
            ("CAP-IO-001", "Could not save %@.", "error.CAP-IO-001"),
            ("CAP-LIM-001", "Too large.", "error.CAP-LIM-001"),
            ("CAP-LIM-003", "Trimmed %d files.", "error.CAP-LIM-003"),
        ]
    )
    func argumentKindMismatchFails(raw: String, template: String, key: String) throws {
        // given the shipped catalogue with one template rewritten
        let data = try Check.mutatedShippedData { $0["error.\(raw)"] = Check.entry(template) }
        let catalogue = try FlotsamCatalogue.englishStrings(from: data).get()
        #expect(catalogue["error.\(raw)"] == template, "precondition: the mutation reached the reader")
        // when the consistency check runs, then exactly that key is reported
        #expect(Check.violations(catalogue: catalogue, codes: Check.shippedCodes) == ["argumentKinds:\(key)"])
    }

    /// OC-0021 (6) control. given a rewritten template that still matches its code's kinds (`%@` stays `%@`, a literal
    /// percent is not a placeholder), then the check stays green, so the red rows above are about kinds only.
    @Test("OC-0021 (6) a reworded template with matching specifiers passes")
    func argumentKindMatchPasses() throws {
        let data = try Check.mutatedShippedData {
            $0["error.CAP-LIM-001"] = Check.entry("100%% too big (%@).")
            $0["error.CAP-LIM-003"] = Check.entry("Only %lld kept.")
        }
        let catalogue = try FlotsamCatalogue.englishStrings(from: data).get()
        #expect(Check.violations(catalogue: catalogue, codes: Check.shippedCodes) == [])
    }

    /// OC-0021 reader. given a key whose English value is stripped (only a German value left), then the reader leaves
    /// it out, so the check reports it missing rather than reading another language.
    @Test("OC-0021 a key with no English value reads as missing")
    func keyWithoutEnglishIsMissing() throws {
        let data = try Check.mutatedShippedData {
            $0["error.LIB-OS-001"] = ["localizations": ["de": ["stringUnit": ["state": "translated", "value": "Nur Deutsch"]]]]
        }
        let catalogue = try FlotsamCatalogue.englishStrings(from: data).get()
        #expect(Check.violations(catalogue: catalogue, codes: Check.shippedCodes) == ["missing:error.LIB-OS-001"])
        #expect(!catalogue.values.contains("Nur Deutsch"))
    }

    /// OC-0021 file path. given a mutated copy written to a file, when read through the URL entry point, then the same
    /// failure shows; given a missing file, then the reader fails with SYS-INT-001 instead of an empty catalogue.
    @Test("OC-0021 the URL reader sees a mutated file and fails on a missing one")
    func urlReader() throws {
        let data = try Check.mutatedShippedData { $0["error.SET-OS-001"] = nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-catalogue-\(UUID().uuidString).xcstrings")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let catalogue = try FlotsamCatalogue.englishStrings(at: url).get()
        #expect(Check.violations(catalogue: catalogue, codes: Check.shippedCodes) == ["missing:error.SET-OS-001"])

        let missing = FlotsamCatalogue.englishStrings(at: url.appendingPathExtension("gone"))
        guard case .failure(let error) = missing else {
            Issue.record("a missing catalogue file must fail, got \(missing)")
            return
        }
        #expect(error.code.rawValue == "SYS-INT-001")
        #expect(error.underlying != nil, "the file error's domain and code are kept")
    }

    /// OC-0021 malformed. given bytes that are not JSON, or JSON with no strings table, then the reader fails with
    /// SYS-INT-001 and never returns an empty table that would pass a "no orphan keys" check.
    @Test("OC-0021 a non-JSON or table-less catalogue fails to read", arguments: ["not json at all", "{\"sourceLanguage\":\"en\"}", "[]"])
    func malformedCatalogueFails(text: String) {
        let result = FlotsamCatalogue.englishStrings(from: Data(text.utf8))
        guard case .failure(let error) = result else {
            Issue.record("expected failure for \(text), got \(result)")
            return
        }
        #expect(error.code.rawValue == "SYS-INT-001")
    }
}
