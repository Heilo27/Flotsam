import Foundation
import Testing

@testable import FlotsamBase

// TASK-488 blind QA (Worf): macOS 26+ only means the ungated-pasteboard path is gone (FRD-001 FR-001-18), the minimum
// OS lives in one deployment-target literal that LSMinimumSystemVersion derives from (FRD-009 FR-009-11), and every
// memory budget is a physical footprint (AC-001-16). Most of this lives in the app target or in prose, which no package
// test can instantiate, so these are source and spec scans. Every scanner is first run against literal samples so it is
// capable of going red.

private func files(under relative: String, extensions: Set<String>) throws -> [URL] {
    let repo = try frd008SourceRoot()
    let root = repo.appendingPathComponent(relative)
    var result: [URL] = []
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    for case let url as URL in enumerator where extensions.contains(url.pathExtension) {
        // Judge the path inside the repo, so a worktree under `.claude/worktrees` is not itself excluded.
        let inside = String(url.path.dropFirst(repo.path.count))
        if inside.contains("/.build/") || inside.contains("/node_modules/") { continue }
        result.append(url)
    }
    return result
}

/// True when a `ClipboardCapture` initialiser parameter named `access` carries a default value.
private func accessParameterHasDefault(in code: String) -> Bool {
    code.components(separatedBy: "\n").contains { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("access:") && t.contains("=")
    }
}

/// Lines naming a resident-memory budget metric, which the spec replaced with "physical footprint".
private func residentMemoryHits(in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"resident[- ](memory|set|size)"#, options: .caseInsensitive) else { return ["bad regex"] }
    return text.components(separatedBy: "\n").filter {
        regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
    }
}

private func deploymentTarget(inProjectYML yml: String) -> String? {
    guard let r = yml.range(of: #"deploymentTarget:\s*\n\s*macOS:\s*"([0-9.]+)""#, options: .regularExpression) else { return nil }
    return String(yml[r]).components(separatedBy: "\"").dropFirst().first
}

private func platform(inPackage package: String) -> String? {
    guard let r = package.range(of: #"platforms:\s*\[\.macOS\("([0-9.]+)"\)"#, options: .regularExpression) else { return nil }
    return String(package[r]).components(separatedBy: "\"").dropFirst().first
}

@Suite("TASK-488 Worf: macOS 26 only, footprint wording")
struct Worf488AdversarialTests {
    // OC-488-W1. Red if ClipboardCapture.init gets a default for `access:` (an ungated fallback) back.
    @Test("OC-488-W1: ClipboardCapture's access parameter has no default, so no caller can skip the gate")
    func accessIsRequired() throws {
        // given the capture source
        let code = try frd008Code("Packages/FlotsamCore/Sources/FlotsamCapture/ClipboardCapture.swift")
        // when reading the access parameter
        // then it is declared and has no default
        #expect(code.contains("access: any PasteboardAccessPort"))
        #expect(!accessParameterHasDefault(in: code))
        // negative: the scanner flags a defaulted parameter and passes a bare one
        #expect(accessParameterHasDefault(in: "        access: any PasteboardAccessPort = UngatedPasteboardAccess(),"))
        #expect(!accessParameterHasDefault(in: "        access: any PasteboardAccessPort,"))
    }

    // OC-488-W2. Red if the ungated type or the gate flag reappears anywhere shipped (App or package sources).
    @Test("OC-488-W2: no shipped source names UngatedPasteboardAccess or gatesPasteboard")
    func removedSymbolsStayRemoved() throws {
        // given every Swift file in App and the package Sources
        var offenders: [String] = []
        for dir in ["App", "Packages/FlotsamCore/Sources"] {
            for url in try files(under: dir, extensions: ["swift"]) {
                let text = try String(contentsOf: url, encoding: .utf8)
                for symbol in ["UngatedPasteboardAccess", "gatesPasteboard"] where text.contains(symbol) {
                    offenders.append("\(url.lastPathComponent): \(symbol)")
                }
            }
        }
        // then none, and the scan really walked files (positive control: the capture file exists in the walk)
        #expect(offenders.isEmpty, "\(offenders)")
        let walked = try files(under: "Packages/FlotsamCore/Sources", extensions: ["swift"]).map(\.lastPathComponent)
        #expect(walked.contains("ClipboardCapture.swift") && walked.contains("Onboarding.swift"))
    }

    // OC-488-W3. Red if every flow stops showing all eight steps, or a saved step is dropped for any step.
    @Test("OC-488-W3: the flow is every step in order and resuming at each step lands on that step", arguments: OnboardingStep.allCases)
    func everyStepResumesAndNoneIsHidden(step: OnboardingStep) {
        // given a flow resumed at `step`
        let flow = OnboardingFlow(resumingAt: step)
        // then it shows all eight steps in raw order, starts exactly there, and counts from the step's own position
        #expect(flow.steps.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(flow.total == 8)
        #expect(flow.current == step)
        #expect(flow.position == step.rawValue + 1)
        // boundary: step 2 (Clipboard) specifically is never skipped
        #expect(flow.steps.contains(.clipboard))
    }

    // OC-488-W4. Red if a user-facing string again names a pre-26 macOS, or the Paste from Other Apps help changes.
    @Test("OC-488-W4: no string-catalogue value names a macOS below 26; the clipboard help reads 'macOS asks'")
    func catalogueHasNoOldVersions() throws {
        // given the string catalogue
        let text = try frd008Code("Packages/FlotsamCore/Sources/FlotsamBase/Resources/Localizable.xcstrings")
        let values = text.components(separatedBy: "\n").filter { $0.contains("\"value\" :") }
        // when scanning every value for a macOS major below 26 or the 15.4 qualifier
        let regex = try NSRegularExpression(pattern: #"macOS (1[0-9]|[0-9])(\.[0-9]+)?\b|15\.4"#)
        let old = values.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        // then none, the help string is the exact literal, and the catalogue really has values
        #expect(old.isEmpty, "\(old)")
        #expect(text.contains("\"value\" : \"macOS asks before apps read the clipboard. Choose Always Allow.\""))
        #expect(values.count > 100)
        // negative: the scanner flags the old string
        let sample = "\"value\" : \"macOS 15.4 and later asks before apps read the clipboard.\""
        #expect(regex.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil)
    }

    // OC-488-W5. Red if a second deployment literal appears, the two declarations drift apart, or LSMinimumSystemVersion
    // is hardcoded anywhere (project.yml or the checked-in Info.plist).
    @Test("OC-488-W5: one deployment-target literal in project.yml, equal to Package.swift, and LSMinimumSystemVersion derives from it")
    func singleDeploymentLiteral() throws {
        // given the declarations
        let yml = try frd008Code("project.yml")
        let plist = try frd008Code("App/Flotsam/Info.plist")
        let package = try frd008Code("Packages/FlotsamCore/Package.swift")
        // when reading the versions
        let target = try #require(deploymentTarget(inProjectYML: yml))
        let pkg = try #require(platform(inPackage: package))
        // then both are 26.0 (equal to each other, and the major is 26)
        #expect(target == pkg)
        #expect(target == "26.0")
        // and project.yml has exactly one macOS version literal and no second deployment-target setting
        #expect(yml.components(separatedBy: "macOS: \"").count - 1 == 1)
        #expect(!yml.contains("MACOSX_DEPLOYMENT_TARGET:"))
        // and the minimum-version key is derived in both places, never a literal number
        #expect(yml.components(separatedBy: "LSMinimumSystemVersion:").count - 1 == 1)
        #expect(yml.contains("LSMinimumSystemVersion: \"$(MACOSX_DEPLOYMENT_TARGET)\""))
        #expect(plist.components(separatedBy: "<key>LSMinimumSystemVersion</key>").count - 1 == 1)
        let afterKey = try #require(plist.components(separatedBy: "<key>LSMinimumSystemVersion</key>").last)
        let valueLine = try #require(afterKey.components(separatedBy: "\n").first { $0.contains("<string>") })
        #expect(valueLine.contains("$(MACOSX_DEPLOYMENT_TARGET)") && !valueLine.contains("26"))
    }

    // OC-488-W6. Red if a spec or oracle states a memory budget as "resident memory / set / size" again (AC-001-16:
    // the metric is the physical footprint).
    @Test("OC-488-W6: no spec, ADR or oracle states a budget as resident memory; scanner can fail")
    func noResidentMemoryBudgetWording() throws {
        // given the scanner flags the old wording and passes the new and unrelated uses
        #expect(residentMemoryHits(in: "resident memory including a full thumbnail cache stays under 150 MB").count == 1)
        #expect(residentMemoryHits(in: "the 150 MB resident-set check").count == 1)
        #expect(residentMemoryHits(in: "no resident index copy").isEmpty)
        #expect(residentMemoryHits(in: "physical footprint stays under 150 MB").isEmpty)
        // when scanning every markdown doc and every oracle
        var offenders: [String] = []
        for url in try files(under: "docs", extensions: ["md"]) + (try files(under: ".claude/oracle", extensions: ["json"])) {
            // docs/research records what a measurement tool counted (it reads RSS next to the footprint), not a budget
            if url.path.contains("/docs/research/") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            offenders += residentMemoryHits(in: text).map { "\(url.lastPathComponent): \($0.prefix(90))" }
        }
        // then none
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
