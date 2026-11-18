import Foundation
import Testing

@testable import FlotsamBase

// TASK-487 blind QA (Worf): minimum macOS raised to 26 (FRD-009 FR-009-11 / AC-009-10; FRD-001 FR-001-18; FRD-008
// FR-008-12/13). The three removed `#available` branches live in the app target, which no package test can
// instantiate, so those are source scans (precedent: Worf460OnboardingLoginReadGuardTests). The step count is
// behavioural. The version scan is tested against literal samples first so it is capable of going red.

private func source(_ relative: String) throws -> String { try frd008Code(relative) }

/// Macros-below-26 availability checks in `text`: every `#available(macOS N` / `@available(macOS N` with N < 26.
private func availabilityBelow26(in text: String) -> [String] {
    var hits: [String] = []
    guard let regex = try? NSRegularExpression(pattern: #"[#@]available\(\s*macOS\s*(?:\(\s*)?(\d+)(?:\.\d+)*"#) else { return ["bad regex"] }
    let whole = NSRange(text.startIndex..., in: text)
    for match in regex.matches(in: text, range: whole) {
        guard let versionRange = Range(match.range(at: 1), in: text), let major = Int(text[versionRange]) else { continue }
        if major < 26, let r = Range(match.range, in: text) { hits.append(String(text[r])) }
    }
    return hits
}

@Suite("TASK-487 Worf: minimum macOS 26")
struct Worf487MinimumMacOSTests {
    // OC-487-01. Red if the flow drops a step, re-adds the skip, or reorders: the always-on flow is exactly eight steps.
    @Test("OC-487-01: the gated onboarding flow is exactly eight steps, Clipboard second")
    func eightSteps() {
        // given the flow the app builds (every flow shows the Clipboard step on macOS 26)
        var flow = OnboardingFlow()
        // when walking Welcome to Done
        var visited = [flow.current.rawValue]
        var positions = [flow.position]
        while !flow.isLast { flow.advance(); visited.append(flow.current.rawValue); positions.append(flow.position) }
        // then eight distinct steps, clipboard is step 2, Done is step 8 of 8
        #expect(flow.total == 8)
        #expect(visited == [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(positions == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(flow.steps[1] == .clipboard)
        #expect(flow.current == .done)
    }

    // OC-487-02. Red if the model's flow regains a gate parameter or a probe (TASK-488: the gate parameter is gone, so the flow is always gated).
    @Test("OC-487-02: OnboardingModel always builds the flow gated; no probe, no availability branch")
    func modelAlwaysGated() throws {
        // given the model source (comments stripped)
        let code = try source("App/Flotsam/OnboardingModel.swift")
        // when reading how the flow is constructed
        // then there is no gate argument at all (TASK-488) and nothing consults a probe or OS version
        #expect(!code.contains("gatesPasteboard"))
        #expect(!code.contains("isGated"))
        #expect(!code.contains("#available"))
        #expect(!code.contains("ProcessInfo.processInfo.operatingSystemVersion"))
    }

    // OC-487-03. Red if isAllowed regains an OS-version fall-through that returns true (ungated) or isGated returns.
    @Test("OC-487-03: PasteboardAccess.isAllowed is the accessBehavior check alone; isGated is gone")
    func pasteboardAccessAlwaysGated() throws {
        // given the platform source
        let code = try source("App/Platform/PasteboardAccess.swift")
        // when isolating the enum body up to openSystemSettings
        let body = try #require(code.components(separatedBy: "static func openSystemSettings").first)
        // then isAllowed compares accessBehavior to .alwaysAllow, with no availability branch, no `return true`
        #expect(body.contains("NSPasteboard.general.accessBehavior == .alwaysAllow"))
        #expect(!body.contains("#available"))
        #expect(!body.contains("return true"))
        #expect(!body.contains("isGated"))
        #expect(!code.contains("isGated"))
    }

    // OC-487-04. Red if the Open System Settings button goes back behind a condition in the Privacy row.
    @Test("OC-487-04: Privacy 'Paste from Other Apps' row always shows its Open System Settings button")
    func privacyRowAlwaysHasButton() throws {
        // given the Privacy pane source
        let code = try source("App/Flotsam/Settings/PrivacyPane.swift")
        let lines = code.components(separatedBy: "\n")
        // when finding the button's line and the line before it
        let index = try #require(lines.firstIndex { $0.contains("PasteboardAccess.openSystemSettings()") })
        let previous = lines[index - 1].trimmingCharacters(in: .whitespaces)
        // then the button is a direct sibling of the status Text, not inside an `if`
        #expect(previous.hasPrefix("Text(isAllowed"), "line before the button: \(previous)")
        #expect(!code.contains("isGated"))
        #expect(!code.contains("#available"))
    }

    // OC-487-05. Red if any one of the places that state the minimum OS is moved off 26.0. TASK-488: Info.plist no longer
    // holds a literal; it derives from MACOSX_DEPLOYMENT_TARGET, which xcodegen sets from options.deploymentTarget, so the literals live in project.yml (once) and Package.swift.
    @Test("OC-487-05: project.yml and Package.swift state 26.0, Info.plist derives it, nothing else")
    func minimumVersionsAgree() throws {
        // given the declarations
        let yml = try source("project.yml")
        let plist = try source("App/Flotsam/Info.plist")
        let package = try source("Packages/FlotsamCore/Package.swift")
        // when reading them
        // then the literals are 26.0, Info.plist derives from the deployment target, and none keeps the old value
        #expect(yml.contains("macOS: \"26.0\""))
        #expect(!yml.contains("MACOSX_DEPLOYMENT_TARGET:"), "project.yml states the deployment target once, in options.deploymentTarget")
        #expect(yml.contains("LSMinimumSystemVersion: \"$(MACOSX_DEPLOYMENT_TARGET)\""))
        #expect(plist.contains("<key>LSMinimumSystemVersion</key>\n\t<string>$(MACOSX_DEPLOYMENT_TARGET)</string>"))
        #expect(package.contains("platforms: [.macOS(\"26.0\")]"))
        for (name, text) in [("project.yml", yml), ("Info.plist", plist), ("Package.swift", package)] {
            #expect(!text.contains("14.0"), "\(name) still names 14.0")
            #expect(!text.contains(".v14") && !text.contains(".v15"), "\(name) names .v14/.v15")
        }
    }

    // OC-487-06. Red if any app or package source reintroduces an availability check naming macOS below 26.
    @Test("OC-487-06: no #available / @available names a macOS below 26 in App or Packages sources")
    func noAvailabilityBelow26() throws {
        // given every Swift file under App and the package Sources
        let root = try frd008SourceRoot()
        var offenders: [String] = []
        for dir in ["App", "Packages/FlotsamCore/Sources"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)
            for case let url as URL in enumerator ?? FileManager.default.enumerator(atPath: "/")! where
                url.pathExtension == "swift" && !url.path.contains("/.build/")
            {
                let text = try String(contentsOf: url, encoding: .utf8)
                offenders += availabilityBelow26(in: text).map { "\(url.lastPathComponent): \($0)" }
            }
        }
        // then none
        #expect(offenders.isEmpty, "\(offenders)")
    }

    // OC-487-07. The scanner above must be able to fail: it flags below-26 checks and passes 26 and later.
    @Test("OC-487-07: the availability scanner flags macOS 14/15.4 and passes macOS 26", arguments: [
        ("if #available(macOS 15.4, *) { }", 1), ("@available(macOS 14, *)", 1), ("if #available(macOS 26, *) { }", 0),
        ("@available(*, unavailable)", 0), ("if #available(macOS 26.0, *) {} else if #available(macOS 15, *) {}", 1), ("", 0),
    ])
    func scannerCanFail(sample: String, expectedHits: Int) {
        #expect(availabilityBelow26(in: sample).count == expectedHits)
    }

    // OC-487-08. Spec/code agreement (spec sync): FR-008-12 lists eight steps with step 2 never skipped; the enum has eight.
    @Test("OC-487-08: FRD-008 FR-008-12 lists eight steps, step 2 unconditional, matching OnboardingStep")
    func specMatchesStepCount() throws {
        // given FR-008-12 text
        let frd = try String(contentsOf: frd008SourceRoot().appendingPathComponent("docs/frd/FRD-008-OnboardingSettings.md"), encoding: .utf8)
        let line = try #require(frd.components(separatedBy: "\n").first { $0.hasPrefix("- **FR-008-12**") })
        // when counting the "(N)" step markers
        let markers = (1...9).filter { line.contains("(\($0)) ") }
        // then 1...8, no ninth, and no skip clause for step 2; the code has the same eight
        #expect(markers == Array(1...8))
        #expect(!line.contains("otherwise the step is skipped"))
        #expect(OnboardingStep.allCases.count == 8)
    }
}
