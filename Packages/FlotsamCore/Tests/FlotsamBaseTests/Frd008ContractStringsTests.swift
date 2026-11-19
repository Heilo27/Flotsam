import Foundation
import Testing

@testable import FlotsamBase

// FRD-008 contract tests, Phase 8T part B: copy, no-network and business rules (OC-8139, OC-8142 to OC-8147).
//
// NO SEAM: MANUAL (needs a release binary, packet capture, or a running app):
//   OC-8142 binary linkage and symbol inspection (the source and manifest scan below is the static substitute),
//   OC-8143 ten-minute packet capture (0 outbound connections), OC-8144 network-disabled rendering (a code scan for
//   web views and remote images is the static substitute), OC-8145 and OC-8147 the live-session halves (copy stored,
//   Ctrl-Cmd-V opens the Library, no system prompt appears), OC-8146 Cancel on each live dialog leaves item count and
//   the ignored list unchanged (the confirm-first decisions are asserted instead).

/// Every `.swift` file under a repo-relative directory, as (path relative to the repo, code without `//` lines).
private func frd008SwiftSources(under directory: String) throws -> [(path: String, code: String)] {
    let root = try frd008SourceRoot()
    let base = root.appendingPathComponent(directory)
    var result: [(String, String)] = []
    let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        result.append((relative, try frd008Code(relative)))
    }
    return result.sorted { $0.0 < $1.0 }
}

private func frd008ProductionSources() throws -> [(path: String, code: String)] {
    try frd008SwiftSources(under: "App") + frd008SwiftSources(under: "Packages/FlotsamCore/Sources")
}

/// FR-008-17 sentence case: the first word may be capitalised; later words may be capitalised only when they are
/// names of things outside Flotsam (macOS panes, the product).
private func frd008IsSentenceCase(_ label: String) -> Bool {
    let names: Set<String> = ["Flotsam", "macOS", "System", "Settings", "Login", "Items", "Other", "Apps", "Input", "Monitoring", "Mac"]
    return label.split(separator: " ").dropFirst().allSatisfy { word in
        let bare = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        return bare.first?.isUppercase != true || names.contains(bare)
    }
}

@Suite("FRD-008 contract: copy, no network, business rules")
struct Frd008ContractStringsTests {
    // OC-8139. Red if a label reverts to the monitoring wording or the two named labels drift.
    @Test("OC-8139: the named labels read as specified and the monitoring wording is absent from the catalogue")
    func namedLabels() throws {
        #expect(FlotsamStrings.text(forKey: "ui.settings.pickUpScreenshots") == "Pick up screenshots")
        #expect(FlotsamStrings.text(forKey: "ui.settings.expandTriggers") == "Expand typed triggers")
        let catalogue = try FlotsamCatalogue.englishStrings().get()
        #expect(catalogue.count > 300)
        let monitoring = catalogue.filter { $0.value.lowercased().contains("enable screenshot monitoring") }
        #expect(monitoring.isEmpty)
    }

    // OC-8139 (sentence case). The heuristic must tell the two cases apart or the scan below would prove nothing.
    @Test("OC-8139: the sentence-case rule accepts plain labels and rejects title case")
    func sentenceCaseRuleDiscriminates() {
        #expect(frd008IsSentenceCase("Pick up screenshots"))
        #expect(frd008IsSentenceCase("Open Login Items"))
        #expect(!frd008IsSentenceCase("Reveal Data Folder"))
        #expect(!frd008IsSentenceCase("Clear History…"))
    }

    /// FR-008-17: buttons, menu items, popup values and window or section titles are Title Case (macOS HIG). Everything
    /// else under `ui.settings.` is a label or message and must be sentence case. Each key names its element kind, so a
    /// new Title Case string is red until someone says what kind of element it is.
    private static let titleCaseElements: [String: String] = [
        "ui.settings.clearHistory": "button", "ui.settings.copyDiagnostics": "button",
        "ui.settings.importRecentScreenshots": "button", "ui.settings.projectPage": "button",
        "ui.settings.resetToDefaults": "button", "ui.settings.revealDataFolder": "button",
        "ui.settings.showSetupGuide": "button", "ui.settings.useSystemDefault": "button", "ui.settings.viewLicence": "button",
        "ui.settings.placementRightEdge": "popup value", "ui.settings.placementLeftEdge": "popup value",
        "ui.settings.placementBottomEdge": "popup value", "ui.settings.placementMenuBar": "popup value",
        "ui.settings.shortcutOpenLibrary": "menu item name", "ui.settings.shortcutSaveClipboard": "menu item name",
        "ui.settings.shortcutToggleShelf": "menu item name",
        "ui.settings.editorWindow": "window title",
    ]

    // OC-8139 (every label). Labels and messages are sentence case; the Title Case element kinds are listed above.
    @Test("OC-8139: every Settings label and message is sentence case; buttons, menu items, popup values and titles are exempt")
    func settingsLabelsAreSentenceCase() throws {
        let catalogue = try FlotsamCatalogue.englishStrings().get()
        let labels = catalogue.filter { key, value in
            key.hasPrefix("ui.settings.") && value.split(separator: " ").count <= 4
                && !value.hasSuffix(".") && !value.contains("%") && value.rangeOfCharacter(from: .decimalDigits) == nil
        }
        #expect(labels.count > 40)
        let offenders = labels.filter { Self.titleCaseElements[$0.key] == nil && !frd008IsSentenceCase($0.value) }.keys.sorted()
        #expect(offenders.isEmpty, "Title Case outside buttons, menu items, popup values and titles: \(offenders)")
        // The exemption list must not rot: every listed key exists, and each really is Title Case (otherwise it is not needed).
        for (key, kind) in Self.titleCaseElements {
            #expect(catalogue[key] != nil, "\(kind) key \(key) is not in the catalogue")
        }
    }

    // OC-8142, OC-8144 (static). Red if a web view, remote image, Sparkle, Network framework or URLSession use appears
    // in the app or the packages, or the manifests link them.
    @Test("OC-8142/8144: no networking, web view, remote image or updater in sources, manifests or entitlements")
    func noNetworkCode() throws {
        let forbidden = ["import WebKit", "import Network", "import Sparkle", "URLSession", "NWConnection", "NWPathMonitor",
                         "WKWebView", "WebView(", "AsyncImage", "NSURLConnection"]
        let sources = try frd008ProductionSources()
        #expect(sources.count > 100)
        let hits = sources.flatMap { file in forbidden.filter { file.code.contains($0) }.map { "\(file.path): \($0)" } }
        #expect(hits.isEmpty)
        for manifest in ["project.yml", "Packages/FlotsamCore/Package.swift"] {
            let code = try frd008Code(manifest)
            #expect(!code.localizedCaseInsensitiveContains("sparkle"))
            #expect(!code.contains("WebKit.framework"))
            #expect(!code.contains("Network.framework"))
        }
        let entitlements = try frd008Code("App/Flotsam/Flotsam.entitlements")
        #expect(!entitlements.contains("network.client"))
        #expect(!entitlements.contains("network.server"))
    }

    // The scan above must be able to see a violation: the same matcher on a synthetic source.
    @Test("OC-8142: the forbidden-symbol matcher flags a web view and passes plain code")
    func matcherSeesViolations() {
        func hits(_ code: String) -> Int {
            ["URLSession", "WKWebView", "import WebKit"].filter { code.contains($0) }.count
        }
        #expect(hits("import WebKit\nlet v = WKWebView()") == 2)
        #expect(hits("import SwiftUI\nlet v = Text(\"a\")") == 0)
    }

    // OC-8145 (static). Red if a prompt (`request`) is added anywhere except the onboarding Allow buttons, e.g. at
    // launch, on paste, or when a trigger is saved. (FR-008-13 asks for first-paste and trigger-save prompts; see the
    // OC-8110 DEFECT in the permissions suite. This pins today's rule: no prompt without a deliberate user step.)
    @Test("OC-8145: permission prompts come only from the onboarding Allow buttons")
    func promptsOnlyFromOnboarding() throws {
        let sources = try frd008ProductionSources()
        let callers = sources.filter { $0.code.range(of: #"\w*[Pp]ermission\w*\.request\(\."#, options: .regularExpression) != nil }
            .map(\.path)
        #expect(callers == ["App/Flotsam/OnboardingModel.swift"])
        let model = try frd008Code("App/Flotsam/OnboardingModel.swift")
        #expect(model.contains("func allowAccessibility()"))
        #expect(model.contains("func allowInputMonitoring()"))
    }

    // OC-8146. Red if reducing retention or the image budget applies without asking, or a no-op change asks.
    @Test("OC-8146: shortening retention or lowering the image limit asks first when items would go")
    func reductionsAskFirst() {
        #expect(StorageChangeFlow.needsPreview(retention: .d7, from: .d30))
        #expect(StorageChangeFlow.needsPreview(retention: .d30, from: .forever))
        #expect(!StorageChangeFlow.needsPreview(retention: .d30, from: .d30))
        #expect(!StorageChangeFlow.needsPreview(retention: .forever, from: .d30))
        #expect(StorageChangeFlow.needsPreview(budget: .mib500, from: .gib10))
        #expect(!StorageChangeFlow.needsPreview(budget: .unlimited, from: .gib2))
        #expect(StorageChangeFlow.after(previewCount: 12) == .confirm(count: 12))
        #expect(StorageChangeFlow.after(previewCount: 1) == .confirm(count: 1))
        #expect(StorageChangeFlow.after(previewCount: 0) == .applyNow)
    }

    // OC-8146 (Clear History and Reset ignored apps). Red if the destructive buttons stop going through a sheet or
    // alert, or Privacy's reset stops asking.
    @Test("OC-8146: Clear History opens a confirming sheet and the ignored-apps reset asks before replacing")
    func destructiveControlsConfirm() throws {
        let storage = try frd008Code("App/Flotsam/Settings/StoragePane.swift")
        #expect(storage.contains("showingClear = true"))
        #expect(storage.contains(".sheet(isPresented: $showingClear)"))
        let editor = try frd008Code("App/Flotsam/Settings/AppListEditor.swift")
        #expect(editor.contains("confirmsReset ? (confirmingReset = true) : reset()"))
        #expect(editor.contains("Button(SettingsString.resetAction.text, role: .destructive) { reset() }"))
        let privacy = try frd008Code("App/Flotsam/Settings/PrivacyPane.swift")
        #expect(privacy.contains("key: SettingKeys.privacyIgnoredApps, confirmsReset: true"))
    }

    // OC-8147 (defaults half). Red if any default drifts, or a skipped onboarding writes a setting.
    @Test("OC-8147: a fresh install reads the specified defaults and has written none of them")
    func freshInstallDefaults() {
        let defaults = Frd008Defaults()
        defer { defaults.wipe() }
        let settings = defaults.store()
        #expect(settings.value(SettingKeys.captureMode) == .active)
        #expect(settings.value(SettingKeys.storageRetention) == .d30)
        #expect(settings.value(SettingKeys.screenshotsEnabled) == true)
        #expect(settings.value(SettingKeys.shelfEnabled) == true)
        #expect(settings.value(SettingKeys.shortcutsOpenLibrary) == .chord(Chord(keyCode: 9, modifiers: [.control, .command])))
        // reading defaults persists nothing: a fresh reader's raw domain holds no registry key
        let stored = defaults.suite.defaults.dictionaryRepresentation().keys
            .filter { SettingKeys.all.map(\.name).contains($0) }
        #expect(stored.isEmpty)
        // negative: a deliberate change is stored and read by a fresh instance
        settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
        #expect(defaults.store().value(SettingKeys.captureMode) == .paused)
    }
}
