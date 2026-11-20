import Foundation
import Testing

@testable import FlotsamBase

// FRD-008 contract tests, Phase 8T part B: menu-bar item and shared-setting rules (OC-8126 to OC-8141).
//
// NO SEAM: MANUAL (needs a running app, AppKit drawing, VoiceOver or the pasteboard):
//   OC-8126 Dock / Cmd-Tab appearance (config half is scanned below), OC-8128 and OC-8135 live copy after Pause (the mode
//   to capture decision is asserted instead), OC-8130 glyph shapes (labels are asserted), OC-8136 Settings window opening,
//   onboarding window and process exit, OC-8137 light/dark rendering (template flag is scanned), OC-8138 VoiceOver pass.

/// Repo root, found by walking up from this file to `project.yml`. Shared with the other Frd008 contract files.
func frd008SourceRoot() throws -> URL {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) { return url }
        url.deleteLastPathComponent()
    }
    throw Frd008ScanError.noRoot
}

enum Frd008ScanError: Error { case noRoot }

/// Code of a Swift/plist/yml file with whole-line `//` comments removed, so a comment that names a forbidden symbol
/// is not read as use of it.
func frd008Code(_ relativePath: String) throws -> String {
    let url = try frd008SourceRoot().appendingPathComponent(relativePath)
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

private let openLibraryChord = ChordBinding.chord(Chord(keyCode: 9, modifiers: [.control, .command]))  // ⌃⌘V
private let saveClipboardChord = ChordBinding.chord(Chord(keyCode: 1, modifiers: [.option, .command]))  // ⌥⌘S
private let toggleShelfChord = ChordBinding.chord(Chord(keyCode: 25, modifiers: [.command, .shift]))  // ⇧⌘9

@MainActor
private struct Rig {
    let presenter = RecordingPresenter()
    let reporter: ErrorReporter
    init() { reporter = ErrorReporter(presenter: presenter, clock: ManualClock(), sink: RecordingLogSink()) }
}

private func title(_ key: String) -> String? { FlotsamStrings.text(forKey: key) }

@Suite("FRD-008 contract: menu-bar item")
struct Frd008ContractMenuTests {
    // OC-8126 (config half). Red if the agent flag is dropped from either plist source or a window scene or regular
    // activation policy is introduced.
    @Test("OC-8126: the app is an agent with no Dock icon, no scene window and no regular activation")
    func agentApp() throws {
        #expect(try frd008Code("project.yml").contains("LSUIElement: true"))
        let plist = try frd008Code("App/Flotsam/Info.plist")
        #expect(plist.range(of: #"<key>LSUIElement</key>\s*<true/>"#, options: .regularExpression) != nil)
        let app = try frd008Code("App/Flotsam/FlotsamApp.swift")
        #expect(!app.contains("WindowGroup"))
        #expect(!app.contains("Window("))
        let delegate = try frd008Code("App/Flotsam/AppDelegate.swift")
        #expect(!delegate.contains("setActivationPolicy(.regular)"))
    }

    // OC-8127. Red if a row is added, removed, reordered, or a chord is bound to the wrong row.
    @Test("OC-8127: the menu is the fourteen rows in the specified order with the configured chords")
    func menuRowsInOrder() throws {
        let store = Frd008Defaults()
        defer { store.wipe() }
        let settings = store.store()
        settings.set(saveClipboardChord, for: SettingKeys.shortcutsSaveClipboard)
        settings.set(toggleShelfChord, for: SettingKeys.shortcutsToggleShelf)
        let entries = MenuBarModel.entries(settings: settings)
        #expect(entries == [
            .openLibrary(openLibraryChord), .saveClipboard(saveClipboardChord), .addClip(.none), .toggleShelf(toggleShelfChord),
            .separator,
            .captureToggle(titleKey: "ui.menu.pauseCapture", next: .paused), .clearRecent, .notices,
            .separator,
            .settings, .setupGuide,
            .separator,
            .quit,
        ])
        #expect(entries.count == 13)
        #expect(["ui.menu.openLibrary", "ui.menu.saveClipboard", "ui.menu.addClip", "ui.menu.toggleShelf", "ui.menu.pauseCapture",
                 "ui.menu.pauseUntilResume", "ui.menu.clearRecent", "ui.menu.notices", "ui.menu.settings", "ui.menu.setupGuide",
                 "ui.menu.quit"].map(title)
            == ["Open Library", "Save Clipboard to Library", "New Clip from Text…", "Toggle Shelf", "Pause Capture", "Until I Resume",
                "Clear Recent", "Notices", "Settings…", "Show Setup Guide…", "Quit Flotsam"])
    }

    // OC-8127 (key equivalents). Red if the Settings or Quit key equivalent is changed or dropped.
    @Test("OC-8127: Settings is bound to Command-comma and Quit to Command-Q")
    func fixedKeyEquivalents() throws {
        let menu = try frd008Code("App/Flotsam/StatusItemController.swift")
        #expect(menu.contains(#"row("ui.menu.settings", key: ","#))
        #expect(menu.contains(#"row("ui.menu.quit", key: "q""#))
        #expect(menu.contains("NSApplication.shared.terminate(nil)"))
    }

    // OC-8127 wording. Chords render modifiers in the system order (⌃⌥⇧⌘), so Toggle Shelf reads ⇧⌘9
    // (Chord.displayString, and AppKit for the menu row); FR-008-16 states the rule.
    @Test("OC-8127: the Toggle Shelf chord reads as the FRD prints it")
    func chordWordingMatchesFRD() {
        guard case .chord(let chord) = toggleShelfChord else {
            Issue.record("fixture must be a chord")
            return
        }
        #expect(chord.displayString == "⇧⌘9")
    }

    // OC-8128 (model half). Red if Pause stops stopping automatic capture, Resume does not restart it, or the toggle
    // title does not flip.
    @Test("OC-8128: Pause then Resume flips the title and the capture decision, stored through a fresh reader")
    func pauseThenResume() {
        let defaults = Frd008Defaults()
        defer { defaults.wipe() }
        let settings = defaults.store()
        func toggle(_ store: SettingsStore) -> (titleKey: String, next: CaptureMode)? {
            for case .captureToggle(let key, let next) in MenuBarModel.entries(settings: store) { return (key, next) }
            return nil
        }
        #expect(settings.value(SettingKeys.captureMode).capturesClipboardAutomatically == true)
        let pause = toggle(settings)
        #expect(pause?.titleKey == "ui.menu.pauseCapture")
        settings.set(pause?.next ?? .active, for: SettingKeys.captureMode)
        let reader = defaults.store()  // fresh instance
        #expect(reader.value(SettingKeys.captureMode) == .paused)
        #expect(reader.value(SettingKeys.captureMode).capturesClipboardAutomatically == false)
        let resume = toggle(reader)
        #expect(resume?.titleKey == "ui.menu.resumeCapture")
        #expect(title("ui.menu.resumeCapture") == "Resume Capture")
        reader.set(resume?.next ?? .paused, for: SettingKeys.captureMode)
        #expect(defaults.store().value(SettingKeys.captureMode) == .active)
        #expect(defaults.store().value(SettingKeys.captureMode).capturesClipboardAutomatically == true)
    }

    // OC-8129. Red if Curated stops offering Resume, or Resume stops returning to Active.
    // [Spec Drift] FR-007-12 vs FR-008-16: FRD-007 says Curated reads "Pause Capture"; FRD-008 (asserted here) says "Resume Capture".
    // Not resolved here; reported to Friday, no FRD edited. See also the Rule 9 test below.
    @Test("OC-8129: Curated shows Resume Capture and choosing it makes the icon the active one")
    func curatedResumes() {
        let defaults = Frd008Defaults()
        defer { defaults.wipe() }
        let settings = defaults.store()
        settings.set(CaptureMode.curated, for: SettingKeys.captureMode)
        let rows = MenuBarModel.entries(settings: settings)
        #expect(rows.contains(.captureToggle(titleKey: "ui.menu.resumeCapture", next: .active)))
        #expect(!rows.contains(.captureToggle(titleKey: "ui.menu.pauseCapture", next: .paused)))
        settings.set(MenuBarModel.captureToggle(for: .curated).next, for: SettingKeys.captureMode)
        let mode = defaults.store().value(SettingKeys.captureMode)
        #expect(mode == .active)
        #expect(MenuBarModel.icon(mode: mode, hasWarning: false).accessibilityKeys == ["ui.menu.iconActive"])
    }

    // Rule 9 (TASK-473). The Pause/Resume Capture rule has one home, MenuBarModel.captureToggle(for:). The menu row is
    // built from it, so the label a user reads and the mode a click sets cannot diverge, in every mode including Curated
    // (FR-008-16: Curated reads "Resume Capture" and sets Active; FR-007-12 agrees).
    @Test("Rule 9: the menu row's label and next mode come from captureToggle(for:) for every mode, Curated resumes to Active")
    func menuToggleRuleHasOneHome() {
        let expected: [CaptureMode: (titleKey: String, next: CaptureMode)] = [
            .active: ("ui.menu.pauseCapture", .paused),
            .paused: ("ui.menu.resumeCapture", .active),
            .curated: ("ui.menu.resumeCapture", .active),
        ]
        #expect(Set(CaptureMode.allCases) == Set(expected.keys))
        for mode in CaptureMode.allCases {
            let rule = MenuBarModel.captureToggle(for: mode)
            #expect(rule.titleKey == expected[mode]?.titleKey, "label for \(mode)")
            #expect(rule.next == expected[mode]?.next, "next mode for \(mode)")
            let rows = MenuBarModel.entries(mode: mode, shelfEnabled: false, openLibrary: openLibraryChord, saveClipboard: .none, toggleShelf: .none)
            let toggles = rows.compactMap { row -> (String, CaptureMode)? in
                if case .captureToggle(let key, let next) = row { return (key, next) }
                return nil
            }
            #expect(toggles.count == 1, "exactly one toggle row for \(mode)")
            #expect(toggles.first?.0 == rule.titleKey && toggles.first?.1 == rule.next, "row matches the rule for \(mode)")
        }
    }

    // OC-8130 (labels). Red if two modes share a VoiceOver label or a label's wording drifts.
    @Test("OC-8130: the three modes have three different accessibility labels")
    func modeLabelsDiffer() {
        let labels = CaptureMode.allCases.map { mode in
            MenuIcon(mode: mode, warning: false).accessibilityKeys.compactMap(title).joined(separator: ", ")
        }
        #expect(CaptureMode.allCases == [.active, .paused, .curated])
        #expect(labels == ["Flotsam, capturing", "Flotsam, capture paused", "Flotsam, curated capture"])
        #expect(Set(labels).count == 3)
    }

    // OC-8131. Red if a mode drops the dot, if the dot replaces the mode, or Dismiss all leaves a notice.
    @MainActor
    @Test("OC-8131: a warning shows with every mode and Dismiss all removes the notice behind it")
    func warningDotAcrossModes() async {
        let rig = Rig()
        await rig.reporter.report(FlotsamError(.setDat001, "unreadable"), origin: .background)
        #expect(rig.presenter.notices.count == 1)
        for mode in CaptureMode.allCases {
            let keys = MenuBarModel.icon(mode: mode, hasWarning: !rig.presenter.notices.isEmpty).accessibilityKeys
            #expect(keys.count == 2)
            #expect(keys.last == "ui.menu.iconAttention")
        }
        #expect(title("ui.menu.iconAttention") == "Needs attention")
        await rig.reporter.dismissAllNotices()
        #expect(rig.presenter.notices.isEmpty)
        #expect(MenuBarModel.icon(mode: .active, hasWarning: !rig.presenter.notices.isEmpty).accessibilityKeys
            == ["ui.menu.iconActive"])
    }

    // OC-8132. Red if an Info-level report starts creating a notice (and so a dot).
    @MainActor
    @Test("OC-8132: CAP-POL-002 (Info) leaves no notice and no dot")
    func infoLeavesNoDot() async {
        let rig = Rig()
        await rig.reporter.report(FlotsamError(.capPol002, "password manager"), origin: .background)
        #expect(rig.presenter.notices.isEmpty)
        #expect(MenuBarModel.icon(mode: .active, hasWarning: !rig.presenter.notices.isEmpty).warning == false)
    }

    // OC-8133. Red if the Shelf row stays with the Shelf off, or another row goes with it.
    @Test("OC-8133: turning the Shelf off drops exactly Toggle Shelf")
    func shelfOffDropsOneRow() {
        let defaults = Frd008Defaults()
        defer { defaults.wipe() }
        let settings = defaults.store()
        settings.set(toggleShelfChord, for: SettingKeys.shortcutsToggleShelf)
        let before = MenuBarModel.entries(settings: settings)
        settings.set(false, for: SettingKeys.shelfEnabled)
        let after = MenuBarModel.entries(settings: defaults.store())
        #expect(before.count == 13)
        #expect(after.count == before.count - 1)
        #expect(!after.contains(.toggleShelf(toggleShelfChord)))
        #expect(after == before.filter { $0 != .toggleShelf(toggleShelfChord) })
    }

    // OC-8134. Red if a re-recorded chord is not shown, or a cleared chord keeps showing.
    @Test("OC-8134: a re-recorded Open Library chord and a cleared Save Clipboard chord show in the menu")
    func chordsFollowSettings() {
        let defaults = Frd008Defaults()
        defer { defaults.wipe() }
        let settings = defaults.store()
        settings.set(saveClipboardChord, for: SettingKeys.shortcutsSaveClipboard)
        let optionCommandV = ChordBinding.chord(Chord(keyCode: 9, modifiers: [.option, .command]))
        settings.set(optionCommandV, for: SettingKeys.shortcutsOpenLibrary)
        #expect(MenuBarModel.entries(settings: defaults.store()).prefix(2)
            == [.openLibrary(optionCommandV), .saveClipboard(saveClipboardChord)])
        guard case .chord(let chord) = optionCommandV else {
            Issue.record("fixture must be a chord")
            return
        }
        #expect(chord.displayString == "⌥⌘V")
        settings.set(ChordBinding.none, for: SettingKeys.shortcutsSaveClipboard)
        #expect(MenuBarModel.entries(settings: defaults.store()).prefix(2)
            == [.openLibrary(optionCommandV), .saveClipboard(.none)])
    }

    // OC-8135. Red if the entries are remembered from an earlier build instead of read when the menu opens.
    @Test("OC-8135: a mode changed while the menu is closed shows at the next open, both ways")
    func menuIsNeverStale() {
        let defaults = Frd008Defaults()
        defer { defaults.wipe() }
        let writer = defaults.store()
        func toggleTitle() -> String? {
            for case .captureToggle(let key, _) in MenuBarModel.entries(settings: defaults.store()) { return title(key) }
            return nil
        }
        #expect(toggleTitle() == "Pause Capture")
        writer.set(CaptureMode.paused, for: SettingKeys.captureMode)
        #expect(toggleTitle() == "Resume Capture")
        writer.set(CaptureMode.active, for: SettingKeys.captureMode)
        #expect(toggleTitle() == "Pause Capture")
    }

    // OC-8136 (config half). Red if the three terminal rows are reordered or the setup guide is not the second.
    @Test("OC-8136: Settings, Show Setup Guide and Quit are the closing rows in that order")
    func closingRows() {
        let entries = MenuBarModel.entries(
            mode: .active, shelfEnabled: true, openLibrary: .none, saveClipboard: .none, toggleShelf: .none)
        #expect(Array(entries.suffix(5)) == [.separator, .settings, .setupGuide, .separator, .quit])
        #expect(OnboardingFlow().current == .welcome)
    }

    // OC-8137. Red if a menu-bar image is made non-template (it would not adapt to light and dark).
    @Test("OC-8137: every menu-bar image is a template image")
    func iconsAreTemplates() throws {
        let icon = try frd008Code("App/Flotsam/MenuBarIcon.swift")
        // every function that constructs an NSImage must mark it as a template
        let builders = icon.components(separatedBy: "static func ").filter { $0.contains("NSImage(") }
        #expect(builders.count == 2)
        #expect(builders.allSatisfy { $0.contains("isTemplate = true") })
        #expect(!icon.contains("isTemplate = false"))
    }

    // OC-8140. Red if the menu writes anything but capture.mode, or Storage reads a different key.
    @Test("OC-8140: the menu and Storage write the same setting, so Storage shows Paused after the menu pauses")
    func menuAndStorageShareOneKey() throws {
        let defaults = Frd008Defaults()
        defer { defaults.wipe() }
        let storage = defaults.store()
        #expect(storage.value(SettingKeys.captureMode) == .active)
        defaults.store().set(MenuBarModel.captureToggle(for: .active).next, for: SettingKeys.captureMode)
        #expect(storage.value(SettingKeys.captureMode) == .paused)
        #expect(SettingKeys.captureMode.name == "capture.mode")
        let menu = try frd008Code("App/Flotsam/StatusItemController.swift")
        let pane = try frd008Code("App/Flotsam/Settings/StoragePane.swift")
        #expect(menu.contains("set(next, for: SettingKeys.captureMode)"))
        #expect(pane.contains("model.binding(SettingKeys.captureMode)"))
    }

    // OC-8141. Red if a second control for a key appears in another pane or the menu. Panes and menu only: the
    // onboarding overlap is the separate DEFECT test below.
    @Test("OC-8141: across the panes and the menu only capture.mode has two homes")
    func oneControlPerSettingInPanesAndMenu() throws {
        let files = ["AboutPane", "GeneralPane", "LibraryPane", "PrivacyPane", "ShortcutsPane", "StoragePane", "TriggersPane"]
            .map { "App/Flotsam/Settings/\($0).swift" } + ["App/Flotsam/StatusItemController.swift"]
        let homes = try Frd008KeyHomes.scan(files)
        let doubled = homes.filter { $0.value.count > 1 }.keys.sorted()
        #expect(doubled == ["captureMode"])
        #expect(homes["shortcutsOpenLibrary"]?.count == 1)
        #expect(homes.keys.contains("shelfEnabled") && homes.keys.contains("triggersEnabled"))
    }

    // OC-8141 incl. onboarding. FR-008-17: only shortcuts.openLibrary may also appear in onboarding. Red if onboarding
    // (step 5 in particular) touches screenshots.enabled or screenshots.folderOverride, which General controls.
    @Test("OC-8141: onboarding shares only shortcuts.openLibrary with a Settings pane")
    func onboardingOverlap() throws {
        let panes = ["GeneralPane", "LibraryPane", "PrivacyPane", "ShortcutsPane", "StoragePane", "TriggersPane"]
            .map { "App/Flotsam/Settings/\($0).swift" }
        let paneKeys = Set(try Frd008KeyHomes.scan(panes).keys)
        let onboardingKeys = Set(try Frd008KeyHomes.scan(["App/Flotsam/OnboardingModel.swift"]).keys)
        let shared = paneKeys.intersection(onboardingKeys).sorted()
        #expect(shared.contains("shortcutsOpenLibrary"))
        #expect(shared == ["shortcutsOpenLibrary"])
    }
}

/// Which files mention which `SettingKeys.<name>`.
enum Frd008KeyHomes {
    static func scan(_ files: [String]) throws -> [String: Set<String>] {
        var homes: [String: Set<String>] = [:]
        let pattern = try NSRegularExpression(pattern: #"SettingKeys\.([A-Za-z]+)"#)
        for file in files {
            let code = try frd008Code(file)
            let range = NSRange(code.startIndex..., in: code)
            for match in pattern.matches(in: code, range: range) {
                guard let r = Range(match.range(at: 1), in: code) else { continue }
                homes[String(code[r]), default: []].insert(file)
            }
        }
        return homes
    }
}
