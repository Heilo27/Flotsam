import Foundation
import Testing
@testable import FlotsamBase

// FRD-000 8T contract tests, slice Catalogue (oracle .claude/oracle/frd-000-contract.json): the checks that read the
// shipped catalogue and the shipped source tree. Each one has a runtime half (a Release build under `log show`, a
// network monitor, a Finder window) that needs a built app and is listed in FRD000ContractTestsGaps.swift. Expected
// values are literals. Source scans read Packages/FlotsamCore/Sources and App as they are on disk; comment lines are
// skipped so a comment that explains a rule cannot trip the rule.

/// One shipped source file: path relative to the repository root, and its lines.
private struct SourceFile {
    let path: String
    let lines: [String]
}

/// Every text file under Packages/FlotsamCore/Sources and App (Swift, catalogue, plist...). Files that are not UTF-8
/// (images, assets) are skipped.
private func shippedFiles() throws -> [SourceFile] {
    let repo = Repo.root()
    var found: [SourceFile] = []
    for folder in ["Packages/FlotsamCore/Sources", "App"] {
        let base = repo.appendingPathComponent(folder)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = String(url.path.dropFirst(repo.path.count + 1))
            found.append(SourceFile(path: relative, lines: text.components(separatedBy: "\n")))
        }
    }
    return found
}

/// `path:line` of every non-comment line holding `needle`.
private func hits(of needle: String, in files: [SourceFile]) -> [String] {
    files.flatMap { file in
        file.lines.enumerated().compactMap { index, line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), line.contains(needle) else { return nil }
            return "\(file.path):\(index + 1)"
        }
    }
}

@Suite struct FRD000ContractTestsCatalogue {

    // OC-0017. Red if the completion template stops filling the count, or "2" stops being plural.
    @Test("OC-0017 given 2 and 0 items deleted, then the completion HUD reads '2 items deleted' and '0 items deleted'")
    func clearDonePlural() {
        #expect(SettingsString.clearDone.text([.count(2)]) == "2 items deleted")
        #expect(SettingsString.clearDone.text([.count(0)]) == "0 items deleted")
    }

    // OC-0017. [Product defect, reported not fixed] FR-000-05 requires plural and count variations to come from catalogue
    // variations; the catalogue holds one "%lld items deleted" and SettingsString.text(_:) has no variation lookup, so
    // 1 renders "1 items deleted". The expectation below is the contract's: when the defect is fixed this test records no
    // issue, withKnownIssue then fails, and the wrapper is to be removed. Red-to-green if clearDone gains a singular form.
    @Test("OC-0017 given exactly 1 item deleted, then the completion HUD reads '1 item deleted' and never '1 items'")
    func clearDoneSingular() {
        withKnownIssue("OC-0017 product defect: Localizable.xcstrings has no plural variation for ui.settings.clearDone, so 1 reads '1 items deleted'") {
            let hud = SettingsString.clearDone.text([.count(1)])
            #expect(hud == "1 item deleted")
            #expect(!hud.contains("1 items"))
        }
    }

    // OC-0033. Red if a second `.debug`-level emitter is added anywhere, or trace()'s emission moves out of its #if DEBUG
    // block: a Release build would then log Debug entries. (The `log show` comparison is in the Gaps file.)
    @Test("OC-0033 given the shipped sources, then the only .debug emission is FlotsamLog.trace inside #if DEBUG")
    func debugLevelOnlyInsideDebugGate() throws {
        let files = try shippedFiles()

        let debugHits = hits(of: ".debug", in: files).filter { !$0.contains("Resources/") }

        let logPath = "Packages/FlotsamCore/Sources/FlotsamBase/Logging/FlotsamLog.swift"
        #expect(debugHits.count == 1)
        let hit = try #require(debugHits.first)
        #expect(hit.hasPrefix(logPath + ":"))
        let hitLine = try #require(Int(hit.dropFirst(logPath.count + 1)))
        let log = try #require(files.first { $0.path == logPath })
        let opening = try #require(log.lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "#if DEBUG" })
        let closing = try #require(log.lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "#endif" })
        // hitLine is 1-based, the indexes are 0-based.
        #expect(opening + 1 < hitLine && hitLine < closing + 1)
    }

    // OC-0048. Red if any network API enters the shipped sources. (The 5-minute idle capture with a network monitor is in the Gaps file.)
    @Test("OC-0048 given the shipped sources, then 0 lines use a network API")
    func noNetworkAPIs() throws {
        let files = try shippedFiles().filter { $0.path.hasSuffix(".swift") }
        let apis = ["URLSession", "URLRequest", "NSURLConnection", "NWConnection", "NWPathMonitor", "NWListener", "CFNetwork", "CFSocket", "WKWebView", "import Network", "Sparkle"]

        let found = apis.flatMap { api in hits(of: api, in: files).map { "\(api) \($0)" } }

        #expect(found.isEmpty, "network API found: \(found)")
        // A scan that finds nothing in an empty tree proves nothing: the tree is the real one.
        #expect(files.count > 100)
    }

    // OC-0074. Red if either retired code returns to ErrorCode, or its catalogue key or text returns.
    @Test("OC-0074 OC-0075 given the retired codes ORG-VAL-004 and ORG-VAL-005, then ErrorCode has neither and the catalogue holds neither key nor text")
    func retiredCodesAbsentFromCodeAndCatalogue() throws {
        let catalogue = try Repo.catalogue()

        #expect(ErrorCode(rawValue: "ORG-VAL-004") == nil)
        #expect(ErrorCode(rawValue: "ORG-VAL-005") == nil)
        #expect(FlotsamStrings.text(forKey: "error.ORG-VAL-004") == nil)
        #expect(FlotsamStrings.text(forKey: "error.ORG-VAL-005") == nil)
        #expect(catalogue["error.ORG-VAL-004"] == nil)
        #expect(catalogue["error.ORG-VAL-005"] == nil)
        #expect(!catalogue.values.contains("Select at least two files, folders or images to group."))
        #expect(!catalogue.values.contains("Names must be 1 to 80 characters."))
        // The live ORG-VAL codes are still there, so the checks above are not vacuous.
        #expect(ErrorCode(rawValue: "ORG-VAL-001") != nil)
        #expect(ErrorCode(rawValue: "ORG-VAL-003") != nil)
        #expect(catalogue["error.ORG-VAL-001"] == "Tag names must be 1 to 32 characters and unique.")
    }

    // OC-0075. Red if any shipped file (Swift source, catalogue, plist) names a retired code or text. The source tree is
    // what the Release executable and compiled catalogue are built from; the built binary itself is in the Gaps file.
    @Test("OC-0075 given the shipped sources and catalogue, then 0 occurrences of the retired codes, catalogue keys and texts")
    func retiredStringsAbsentFromShippedFiles() throws {
        let files = try shippedFiles()
        let retired = [
            "ORG-VAL-004", "ORG-VAL-005", "error.ORG-VAL-004", "error.ORG-VAL-005",
            "Select at least two files, folders or images to group.", "Names must be 1 to 80 characters.",
        ]

        let found = retired.flatMap { text in hits(of: text, in: files).map { "\(text) \($0)" } }

        #expect(found.isEmpty, "retired text shipped: \(found)")
        #expect(files.contains { $0.path.hasSuffix("Localizable.xcstrings") })
    }
}
