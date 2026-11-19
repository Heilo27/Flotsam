import Foundation
import Testing
@testable import FlotsamBase

/// FRD-008 contract tests, oracle OC-8023...OC-8081 at the settings-logic level (panes, permissions, lists, folder
/// choice, storage-change flow). The Storage deletion semantics are in FlotsamStorageTests/Frd008ContractStorageTests
/// and the capture-side ignore behaviour in FlotsamCaptureTests/Frd008ContractIgnoredAppsTests.
/// Expected values are literals from the oracle. DEFECT rows are kept inside `withKnownIssue`.
@Suite struct Frd008ContractSettingsTests {
    private struct Probe: PermissionProbe {
        var accessibility: Bool
        var inputMonitoring: Bool
        func isGranted(_ kind: PermissionKind) -> Bool { kind == .accessibility ? accessibility : inputMonitoring }
        func request(_ kind: PermissionKind) {}
        func openSystemSettings(_ kind: PermissionKind) {}
    }

    private func isolated() -> (SettingsStore, ReportedKeys, () -> Void) {
        let name = "flotsam.frd008.settings.\(UUID().uuidString)"
        let reported = ReportedKeys()
        let store = SettingsStore(
            store: UserDefaultsStore(defaults: UserDefaults(suiteName: name)!), onInvalid: { reported.add($0) })
        return (store, reported, { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) })
    }

    private static let defaultIgnored: Set<String> = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]
    private static let defaultExcluded: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
        "io.alacritty", "dev.warp.Warp-Stable", "co.zeit.hyper", "com.microsoft.rdc.macos",
        "com.apple.ScreenSharing", "com.parallels.desktop.console", "com.vmware.fusion",
    ]

    // MARK: - Window and panes (OC-8023...8032)

    // OC-8023. Exactly six panes in the stated order with the stated titles.
    @Test func oc8023_sixPanesInOrder() {
        #expect(SettingsPane.allCases.map(\.rawValue) == ["general", "shortcuts", "triggers", "privacy", "storage", "about"])
        #expect(SettingsPane.allCases.map { $0.title.text } == ["General", "Shortcuts", "Triggers", "Privacy", "Storage", "About"])
        #expect(SettingsString.window.text == "Settings")
    }

    // OC-8025. Privacy selected, window closed, relaunch: Privacy is selected both times.
    @Test func oc8025_lastPaneSurvivesCloseAndRelaunch() {
        let name = "flotsam.frd008.pane.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        func launch() -> SettingsStore { SettingsStore(store: UserDefaultsStore(defaults: UserDefaults(suiteName: name)!)) }

        #expect(SettingsPane.lastOpened(in: launch()) == .general)
        SettingsPane.privacy.remember(in: launch())
        #expect(SettingsPane.lastOpened(in: launch()) == .privacy, "reopen, same launch")
        #expect(SettingsPane.lastOpened(in: launch()) != .general)
        SettingsPane.about.remember(in: launch())
        #expect(SettingsPane.lastOpened(in: launch()) == .about, "a later choice replaces the earlier one")
    }

    // OC-8026. Turning the Shelf off is stored at once with no Apply step and survives relaunch.
    @Test func oc8026_changeAppliesWithoutCommitAndSurvivesRelaunch() {
        let name = "flotsam.frd008.apply.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        func launch() -> SettingsStore { SettingsStore(store: UserDefaultsStore(defaults: UserDefaults(suiteName: name)!)) }
        let window = launch()
        #expect(window.value(SettingKeys.shelfEnabled) == true)

        window.set(false, for: SettingKeys.shelfEnabled)

        #expect(launch().value(SettingKeys.shelfEnabled) == false, "a fresh store sees it with nothing else done")
        #expect(SettingsString.allCases.allSatisfy { !["Apply", "Save", "OK"].contains($0.text) || $0 == .editorSave },
                "no Settings string is an Apply, Save or OK button (the shortcut editor's Save is FR-005, not a pane)")
    }

    // OC-8030. General's popup and buttons: four placements in order and the stated button texts.
    @Test func oc8030_generalPaneLabelsAndPlacementItems() {
        #expect(ShelfPlacement.allCases.map { $0.label.text } == ["Right Edge", "Left Edge", "Bottom Edge", "Menu Bar"])
        #expect(SettingsString.chooseFolder.text == "Choose…")
        #expect(SettingsString.useSystemDefault.text == "Use System Default")
        #expect(SettingsString.showSetupGuide.text == "Show Setup Guide…")
        #expect(SettingsString.pickUpScreenshots.text == "Pick up screenshots")
    }

    // OC-8031. The Reveal switch is enabled with the Shelf on at a screen edge, disabled when off or in the menu bar.
    @Test func oc8031_revealSwitchEnabledRule() {
        #expect(ShelfRevealRule.isEnabled(shelfEnabled: true, placement: .rightEdge) == true, "(1)")
        #expect(ShelfRevealRule.isEnabled(shelfEnabled: false, placement: .rightEdge) == false, "(2)")
        #expect(ShelfRevealRule.isEnabled(shelfEnabled: true, placement: .menuBar) == false, "(3)")
        #expect(ShelfRevealRule.isEnabled(shelfEnabled: true, placement: .leftEdge) == true, "(4)")
        #expect(ShelfRevealRule.isEnabled(shelfEnabled: true, placement: .bottomEdge) == true)
        #expect(ShelfRevealRule.isEnabled(shelfEnabled: false, placement: .menuBar) == false)
    }

    // OC-8032. Show Setup Guide starts onboarding at step 1, even once onboarding is completed.
    @Test func oc8032_setupGuideOpensOnStepOne() {
        let (settings, _, cleanup) = isolated(); defer { cleanup() }
        settings.set(true, for: SettingKeys.onboardingCompleted)

        let flow = OnboardingFlow()

        #expect(flow.current == .welcome)
        #expect(flow.isFirst)
        #expect(flow.position == 1)
        #expect(OnboardingFlow.shouldShowAutomatically(settings: settings) == false, "completed: the guide is manual only")
        #expect(FlotsamStrings.text(forKey: "ui.menu.setupGuide") == "Show Setup Guide…")
    }

    // OC-8033 (settings half). Turning pickup off and on is a stored boolean read by the watcher.
    @Test func oc8033_pickupSwitchIsStored() {
        let (settings, _, cleanup) = isolated(); defer { cleanup() }
        #expect(settings.value(SettingKeys.screenshotsEnabled) == true)
        settings.set(false, for: SettingKeys.screenshotsEnabled)
        #expect(settings.value(SettingKeys.screenshotsEnabled) == false)
        settings.set(true, for: SettingKeys.screenshotsEnabled)
        #expect(settings.value(SettingKeys.screenshotsEnabled) == true)
    }

    // MARK: - Shortcuts (OC-8034, OC-8035)

    // OC-8034. Three rows with these labels, and the footnote.
    @Test func oc8034_shortcutsPaneStrings() {
        #expect(SettingsString.shortcutOpenLibrary.text == "Open Library")
        #expect(SettingsString.shortcutSaveClipboard.text == "Save Clipboard")
        #expect(SettingsString.shortcutToggleShelf.text == "Toggle Shelf")
        #expect(SettingsString.shortcutsFootnote.text == "Shortcuts for single items and typed triggers are set from the Library (⌘K).")
        #expect(SettingsString.shortcutClear.text == "Clear shortcut")
        let bound = SettingKeys.all.filter { $0.name.hasPrefix("shortcuts.") }.map(\.name)
        #expect(bound == ["shortcuts.openLibrary", "shortcuts.saveClipboard", "shortcuts.toggleShelf"], "exactly three shortcut settings")
    }

    // OC-8035. Clearing Open Library persists unbound, the menu row shows no chord, and a relaunch keeps it unbound.
    @Test func oc8035_clearedShortcutStaysClearedAndMenuShowsNoChord() {
        let name = "flotsam.frd008.clear.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        func launch() -> SettingsStore { SettingsStore(store: UserDefaultsStore(defaults: UserDefaults(suiteName: name)!)) }
        #expect(launch().value(SettingKeys.shortcutsOpenLibrary).persisted == "9:3")

        launch().set(.none, for: SettingKeys.shortcutsOpenLibrary)

        let relaunched = launch()
        #expect(relaunched.value(SettingKeys.shortcutsOpenLibrary) == ChordBinding.none, "not restored to the default on relaunch")
        let openLibrary = MenuBarModel.entries(settings: relaunched).compactMap { entry -> ChordBinding? in
            if case .openLibrary(let binding) = entry { return binding }
            return nil
        }
        #expect(openLibrary == [ChordBinding.none], "exactly one Open Library row, with no chord")
    }

    // MARK: - Triggers (OC-8036...8043)

    // OC-8036 (strings). The rows named by the oracle.
    @Test func oc8036_triggersPaneStrings() {
        #expect(SettingsString.expandTriggers.text == "Expand typed triggers")
        #expect(SettingsString.permissionAccessibility.text == "Accessibility")
        #expect(SettingsString.permissionInputMonitoring.text == "Input Monitoring")
        #expect(SettingsString.openSystemSettings.text == "Open System Settings")
        #expect(SettingsString.resetToDefaults.text == "Reset to Defaults")
        #expect(PermissionKind.allCases.count == 2, "two permission rows")
        #expect(PermissionRow.current(probe: Probe(accessibility: true, inputMonitoring: true)).count == 2)
    }

    // OC-8037. Input Monitoring missing: the inline text exists while triggers are on, and is absent once off.
    @Test func oc8037_inputMonitoringNoticeFollowsTheSwitch() {
        let probe = Probe(accessibility: true, inputMonitoring: false)

        #expect(TriggerPermissionNotice.missing(triggersEnabled: true, probe: probe) == [.setPrm002])
        #expect(TriggerPermissionNotice.missing(triggersEnabled: false, probe: probe) == [])
        #expect(FlotsamStrings.text(forKey: "error.SET-PRM-002")
                == "Input Monitoring is off, so typed triggers are paused. Turn it on in System Settings › Privacy & Security.")
    }

    // OC-8038. Accessibility missing: the notice is SET-PRM-001 and the row reads Not granted.
    @Test func oc8038_accessibilityMissing() {
        let probe = Probe(accessibility: false, inputMonitoring: true)
        let rows = PermissionRow.current(probe: probe)

        #expect(TriggerPermissionNotice.missing(triggersEnabled: true, probe: probe) == [.setPrm001])
        #expect(rows.first { $0.kind == .accessibility }?.status.text == "Not granted")
        #expect(rows.first { $0.kind == .inputMonitoring }?.status.text == "Granted")
        let text = TriggerPermissionNotice.text(for: .setPrm001)
        #expect(text.contains("Accessibility"))
        #expect(text.lowercased().contains("trigger"))
    }

    // OC-8039. Both granted: nothing inline, both rows Granted. Both missing: both codes, in a stable order.
    @Test func oc8039_bothGrantedShowsNothing() {
        let granted = Probe(accessibility: true, inputMonitoring: true)
        #expect(TriggerPermissionNotice.missing(triggersEnabled: true, probe: granted) == [])
        #expect(PermissionRow.current(probe: granted).map(\.status.text) == ["Granted", "Granted"])

        let none = Probe(accessibility: false, inputMonitoring: false)
        #expect(TriggerPermissionNotice.missing(triggersEnabled: true, probe: none) == [.setPrm001, .setPrm002])
    }

    // OC-8040. Add, add again, remove on the excluded list: 11 -> 12 -> 12 -> 11, identity and order preserved.
    @Test func oc8040_addDuplicateRemove() {
        let start = BundleIdentifierList.defaultTriggerExcludedApps
        #expect(start.identifiers.count == 11)

        let added = start.adding("com.apple.Safari")
        #expect(added.identifiers.count == 12)
        #expect(added.identifiers.contains("com.apple.Safari"))
        #expect(Set(added.identifiers).isSuperset(of: Self.defaultExcluded), "no default was lost by the add")

        let again = added.adding("com.apple.Safari")
        #expect(again.identifiers.count == 12, "the duplicate is ignored silently")
        #expect(again == added)

        let removed = again.removing("com.apple.Safari")
        #expect(removed.identifiers.count == 11)
        #expect(!removed.identifiers.contains("com.apple.Safari"))
        #expect(Set(removed.identifiers) == Self.defaultExcluded)
        #expect(start.removing("com.not.in.list").identifiers == start.identifiers, "removing an absent id changes nothing")
    }

    // OC-8041. A bundle with no identifier is refused with SET-VAL-002 and the list is untouched.
    @Test func oc8041_noBundleIdentifierIsRefused() {
        let before = BundleIdentifierList.defaultTriggerExcludedApps
        for raw in [nil, "", "   ", "has space"] as [String?] {
            let result = BundleIdentifierList.validated(raw)
            guard case .failure(let error) = result else { Issue.record("\(String(describing: raw)) must be refused"); continue }
            #expect(error.code == .setVal002)
        }
        #expect(FlotsamStrings.text(forKey: "error.SET-VAL-002") == "That isn't an app Flotsam can add. Choose an application.")
        #expect(before.identifiers.count == 11, "list unchanged: the refused id was never added")
        if case .success(let id) = BundleIdentifierList.validated(" com.apple.Safari\n") { #expect(id == "com.apple.Safari") }
        else { Issue.record("a real identifier must be accepted") }
    }

    // OC-8042. Reset to Defaults on the excluded list yields exactly the eleven and drops user additions.
    @Test func oc8042_resetRestoresTheElevenDefaults() {
        let (settings, _, cleanup) = isolated(); defer { cleanup() }
        let edited = BundleIdentifierList(["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.Safari"])
        settings.set(edited, for: SettingKeys.triggersExcludedApps)
        #expect(settings.value(SettingKeys.triggersExcludedApps).identifiers.count == 3)

        settings.set(SettingKeys.triggersExcludedApps.defaultValue, for: SettingKeys.triggersExcludedApps)

        let after = settings.value(SettingKeys.triggersExcludedApps).identifiers
        #expect(after.count == 11)
        #expect(Set(after) == Self.defaultExcluded)
        #expect(!after.contains("com.apple.Safari"))
    }

    // OC-8043 has no seam here: the request is issued by the App target's Triggers pane against the real
    // Input Monitoring API. The pure half is that the probe asks nothing at construction.
    @Test func oc8043_notGrantedIsReadWithoutRequesting() {
        final class Recording: PermissionProbe, @unchecked Sendable {
            var requested: [PermissionKind] = []
            func isGranted(_ kind: PermissionKind) -> Bool { false }
            func request(_ kind: PermissionKind) { requested.append(kind) }
            func openSystemSettings(_ kind: PermissionKind) {}
        }
        let probe = Recording()
        _ = PermissionRow.current(probe: probe)
        _ = TriggerPermissionNotice.missing(triggersEnabled: true, probe: probe)
        _ = PasteGate.isAllowed(probe: probe)
        #expect(probe.requested.isEmpty, "reading status never asks macOS for a permission")
    }

    // MARK: - Privacy (OC-8044, OC-8069)

    // OC-8044 (strings). The read-only statements and the 'Paste from Other Apps' row text.
    @Test func oc8044_privacyPaneStrings() {
        #expect(SettingsString.neverStored.text == "Transient copies are never stored. Password manager copies are stored encrypted, shown as dots, and need your password or Touch ID.")
        #expect(SettingsString.noNetwork.text == "Flotsam makes no network connections.")
        #expect(SettingsString.pasteOtherApps.text == "Paste from Other Apps")
        #expect(SettingsString.ignoredApps.text == "Ignored apps")
    }

    // OC-8069, as changed by TASK-498 (FR-008-11, AC-008-06). The ignored list defaults to empty: password managers'
    // concealed copies are stored encrypted, so nothing is ignored until the user says so.
    @Test func oc8069_ignoredAppsDefault() {
        let (settings, _, cleanup) = isolated(); defer { cleanup() }
        #expect(settings.value(SettingKeys.privacyIgnoredApps).identifiers.isEmpty)
        #expect(SettingKeys.privacyIgnoredApps.defaultValue.persisted == "[]")
    }

    // MARK: - Storage pane (OC-8046, OC-8047 text, OC-8049...8054)

    // OC-8046. Option lists and their order.
    @Test func oc8046_storageOptionLists() {
        #expect(RetentionPreset.allCases.map { $0.label.text } == ["7 days", "30 days", "90 days", "1 year", "Forever"])
        #expect(ImageBudget.allCases.map { $0.label.text } == ["500 MB", "2 GB", "10 GB", "Unlimited"])
        #expect(ImageQuality.allCases.map { $0.label.text } == ["Original", "Balanced", "Efficient"])
        #expect(CaptureMode.allCases.map { $0.label.text } == ["Active", "Paused", "Curated"])
        #expect(SettingsString.clearHistory.text == "Clear History…")
        #expect(SettingsString.revealDataFolder.text == "Reveal Data Folder")
    }

    // OC-8047 (text). The budget-lowering alert text names N and Z. The alert says 'image budget'.
    @Test func oc8047_budgetAlertText() {
        let text = SettingsString.confirmBudget.text([.count(7), .byteSize(1_048_576)])

        #expect(text.contains("removes 7 older images ("), "the real count is interpolated: \(text)")
        #expect(text.hasSuffix("). Pinned and shortcut items are kept."))
        #expect(text.hasPrefix("Lowering the image budget removes 7 older images ("))
    }

    // OC-8047/8048 (flow). Lowering the budget needs a preview; a preview above zero asks, and Cancel/Confirm are the caller's.
    @Test func oc8047_loweringBudgetAsksOnlyWhenSomethingWouldGo() {
        #expect(StorageChangeFlow.needsPreview(budget: .mib500, from: .gib2) == true)
        #expect(StorageChangeFlow.after(previewCount: 10) == .confirm(count: 10))
        #expect(StorageChangeFlow.after(previewCount: 1) == .confirm(count: 1), "boundary: one image still asks")
    }

    // OC-8049. A change that would remove nothing applies at once.
    @Test func oc8049_zeroPreviewAppliesImmediately() {
        #expect(StorageChangeFlow.after(previewCount: 0) == .applyNow)
    }

    // OC-8050. Raising the budget needs no preview, so no confirmation can appear.
    @Test func oc8050_raisingBudgetNeverAsks() {
        #expect(StorageChangeFlow.needsPreview(budget: .gib10, from: .mib500) == false)
        #expect(StorageChangeFlow.needsPreview(budget: .unlimited, from: .gib2) == false)
        #expect(StorageChangeFlow.needsPreview(budget: .gib2, from: .gib2) == false, "same value is not a reduction")
    }

    // OC-8051. Shortening retention asks; the shorten text carries the count and the period.
    @Test func oc8051_shorteningRetentionAsks() {
        #expect(StorageChangeFlow.needsPreview(retention: .d7, from: .d90) == true)
        #expect(StorageChangeFlow.after(previewCount: 4) == .confirm(count: 4))
        let text = SettingsString.confirmShorten.text(count: 4, label: .retention7Days)
        #expect(text == "This permanently deletes 4 items older than 7 days. Pinned items and items with a shortcut are kept.")
    }

    // OC-8053. Lengthening retention never asks.
    @Test func oc8053_lengtheningRetentionNeverAsks() {
        #expect(StorageChangeFlow.needsPreview(retention: .d90, from: .d7) == false)
        #expect(StorageChangeFlow.needsPreview(retention: .forever, from: .y1) == false)
        #expect(StorageChangeFlow.needsPreview(retention: .d30, from: .d30) == false)
        #expect(StorageChangeFlow.needsPreview(retention: .d7, from: .forever) == true, "Forever to 7 days is the largest reduction")
    }

    // OC-8054. The empty-range text.
    @Test func oc8054_nothingToClearText() {
        #expect(SettingsString.clearNothing.text == "Nothing to clear in this range.")
        #expect(SettingsString.rangeLastHour.text == "Last hour")
        #expect(SettingsString.clearDelete.text == "Delete")
    }

    // MARK: - About (OC-8058...8061)

    // OC-8058. About names MIT, offers no update control.
    @Test func oc8058_aboutContents() {
        #expect(SettingsString.licenceLine.text == "Released under the MIT licence.")
        #expect(SettingsString.viewLicence.text == "View Licence")
        #expect(SettingsString.copyDiagnostics.text == "Copy Diagnostics")
        #expect(SettingsString.projectPage.text == "Project Page")
        #expect(SettingsString.version.text(version: "1.2", build: "34") == "Version 1.2 (34)")
        let updateish = SettingsString.allCases.filter { $0.text.lowercased().contains("update") }
        #expect(updateish.isEmpty, "no update text in Settings: \(updateish)")
    }

    // OC-8059. The licence is a bundled file, so it needs no network, and it is the MIT text.
    @Test func oc8059_licenceIsBundledMIT() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let licence = try String(contentsOf: root.appendingPathComponent("LICENSE"), encoding: .utf8)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)

        #expect(licence.contains("MIT License"))
        #expect(licence.contains("Permission is hereby granted, free of charge"))
        #expect(project.contains("- path: LICENSE"), "LICENSE is copied into the app bundle")
    }

    // OC-8060 (strings). The HUD text.
    @Test func oc8060_diagnosticsCopiedText() {
        #expect(SettingsString.diagnosticsCopied.text == "Diagnostics copied")
    }

    // OC-8061 (static half). No production code opens a network connection, so About cannot make one.
    @Test func oc8061_noNetworkAPIsInProductionCode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var scanned = 0
        var hits: [String] = []
        for folder in ["Packages/FlotsamCore/Sources", "App"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    for needle in ["URLSession", "NWConnection", "URLRequest", "CFSocket", "NSURLConnection", "WKWebView"]
                    where line.contains(needle) { hits.append("\(url.lastPathComponent): \(needle)") }
                }
            }
        }
        #expect(scanned > 100, "the scan read the sources (\(scanned) files)")
        #expect(hits.isEmpty, "network API in production code: \(hits)")
    }

    // MARK: - Screenshot folder (OC-8063, OC-8064, OC-8068)

    private func makeDirectory(permissions: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-frd008-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    // OC-8063. A folder with read permission removed is refused with SET-VAL-001 and the text from the oracle.
    @Test func oc8063_unreadableFolderIsRefused() throws {
        let readable = try makeDirectory(permissions: 0o755)
        let blocked = try makeDirectory(permissions: 0o000)
        defer { remove(readable); remove(blocked) }

        guard case .failure(let error) = FolderOverride.choosing(blocked) else {
            Issue.record("a chmod 000 folder must be refused"); return
        }
        #expect(error.code == .setVal001)
        #expect(FlotsamStrings.text(forKey: "error.SET-VAL-001") == "That folder can't be used for screenshots. Choose a folder you can read.")

        guard case .success(let good) = FolderOverride.choosing(readable) else {
            Issue.record("a readable folder must be accepted: the refusal above is about permissions, not about every folder"); return
        }
        #expect(good.resolvedURL?.lastPathComponent == readable.lastPathComponent, "the previous value A stays intact and resolves")
    }

    // OC-8064. An execute-only folder (not listable) is refused with SET-VAL-001.
    @Test func oc8064_nonListableFolderIsRefused() throws {
        let executeOnly = try makeDirectory(permissions: 0o111)
        defer { remove(executeOnly) }

        guard case .failure(let error) = FolderOverride.choosing(executeOnly) else {
            Issue.record("a chmod 111 folder must be refused"); return
        }
        #expect(error.code == .setVal001)
    }

    // OC-8062 (logic half). A file, or a path that does not exist, is not a choosable folder.
    @Test func oc8062_filesAndMissingPathsAreNotFolders() throws {
        let dir = try makeDirectory(permissions: 0o755)
        defer { remove(dir) }
        let file = dir.appendingPathComponent("a.png")
        try Data([1, 2, 3]).write(to: file)

        for url in [file, dir.appendingPathComponent("missing")] {
            guard case .failure(let error) = FolderOverride.choosing(url) else { Issue.record("\(url.lastPathComponent) must be refused"); continue }
            #expect(error.code == .setVal001)
        }
    }

    // OC-8066 (settings half). Use System Default stores no override.
    @Test func oc8066_useSystemDefaultClearsTheOverride() throws {
        let (settings, _, cleanup) = isolated(); defer { cleanup() }
        let dir = try makeDirectory(permissions: 0o755)
        defer { remove(dir) }
        guard case .success(let chosen) = FolderOverride.choosing(dir) else { Issue.record("folder must be accepted"); return }
        settings.set(chosen, for: SettingKeys.screenshotsFolderOverride)
        #expect(settings.value(SettingKeys.screenshotsFolderOverride).resolvedURL?.lastPathComponent == dir.lastPathComponent)

        settings.set(FolderOverride.none, for: SettingKeys.screenshotsFolderOverride)

        #expect(settings.value(SettingKeys.screenshotsFolderOverride).resolvedURL == nil)
        #expect(settings.value(SettingKeys.screenshotsFolderOverride) == FolderOverride.none)
    }

    // OC-8065 (settings half). A chosen folder survives a relaunch and still resolves to the same folder.
    @Test func oc8065_chosenFolderSurvivesRelaunch() throws {
        let name = "flotsam.frd008.folder.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        func launch() -> SettingsStore { SettingsStore(store: UserDefaultsStore(defaults: UserDefaults(suiteName: name)!)) }
        let dir = try makeDirectory(permissions: 0o755)
        defer { remove(dir) }
        guard case .success(let chosen) = FolderOverride.choosing(dir) else { Issue.record("folder must be accepted"); return }

        launch().set(chosen, for: SettingKeys.screenshotsFolderOverride)

        #expect(launch().value(SettingKeys.screenshotsFolderOverride).resolvedURL?.lastPathComponent == dir.lastPathComponent)
    }

    // OC-8068. The missing-folder text.
    @Test func oc8068_missingFolderText() {
        #expect(FlotsamStrings.text(forKey: "error.SSP-IO-003") == "Your chosen screenshot folder is missing. Screenshot pickup is paused.")
    }

    // MARK: - Ignored apps list (OC-8075...8080)

    // OC-8075. An app with no identifier is refused with the oracle text; the list is unchanged. The oracle says the
    // button reads 'Add…'.
    @Test func oc8075_addWithoutIdentifierRefusedAndButtonLabel() {
        let defaults = BundleIdentifierList.retiredIgnoredAppsDefault
        guard case .failure(let error) = BundleIdentifierList.validated(nil) else { Issue.record("nil id must be refused"); return }

        #expect(error.code == .setVal002)
        #expect(defaults.identifiers.count == 6)
        #expect(Set(defaults.identifiers) == Self.defaultIgnored)
        #expect(SettingsString.addApp.text == "Add…")
    }

    // OC-8076. Adding 1Password 8 again changes nothing.
    @Test func oc8076_addingAnExistingAppIsIgnored() {
        let defaults = BundleIdentifierList.retiredIgnoredAppsDefault
        let again = defaults.adding("com.1password.1password")
        #expect(again.identifiers.count == 6)
        #expect(again == defaults)
        #expect(defaults.adding("com.apple.TextEdit").identifiers.count == 7, "a new id is added")
    }

    // OC-8077/8078 are App-target UI (open panel, icons): no seam. Logic half of 8078: an id with no app installed is
    // still a valid list entry, shown as its identifier.
    @Test func oc8078_uninstalledIdentifiersStayInTheList() {
        let list = BundleIdentifierList.retiredIgnoredAppsDefault.adding("com.example.not-installed")
        #expect(list.identifiers.last == "com.example.not-installed")
        #expect(SettingsString.notInstalled.text == "Not installed")
    }

    // OC-8079 (AC-008-06, package half). The confirm-then-reset branch and the Cancel button live only in the SwiftUI
    // view App/Flotsam/Settings/AppListEditor.swift (`confirmsReset ? confirmingReset = true : reset()`; Cancel is an
    // empty closure). That decision is App-only and cannot be driven from this package; it needs an app UI test.
    // What the package owns, and what makes "Cancel leaves the list unchanged" true: an edited list is persisted
    // exactly (order, members) and nothing in the settings layer resets it on its own. Given an edited list, when
    // no reset is invoked (the Cancel outcome), then a FRESH store on the same defaults returns exactly that list.
    // Red if `set` drops/reorders entries, if `adding`/`removing` misbehave, or if reading falls back to the defaults.
    @Test func oc8079_editedListSurvivesWhenResetIsNotInvoked() {
        let name = "flotsam.frd008.settings.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        func store() -> SettingsStore {
            SettingsStore(store: UserDefaultsStore(defaults: UserDefaults(suiteName: name)!), onInvalid: { _ in })
        }
        let edited = BundleIdentifierList.retiredIgnoredAppsDefault.removing("com.bitwarden.desktop").adding("com.apple.TextEdit")
        store().set(edited, for: SettingKeys.privacyIgnoredApps)

        let list = store().value(SettingKeys.privacyIgnoredApps).identifiers
        #expect(list == [
            "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
            "com.agilebits.onepassword7", "org.keepassxc.keepassxc", "com.apple.TextEdit",
        ])
        #expect(list != SettingKeys.privacyIgnoredApps.defaultValue.identifiers)
        #expect(SettingsString.confirmResetIgnored.text == "Clear the ignored-apps list? Flotsam will store copies from every app, password managers included.")
    }

    // OC-8080, as changed by TASK-498 (FR-008-11). Confirming the reset yields the defaults, which are now empty: the
    // user's list is gone, including the app they added and the password managers they kept.
    @Test func oc8080_confirmedResetRestoresTheDefaults() {
        let (settings, _, cleanup) = isolated(); defer { cleanup() }
        let edited = BundleIdentifierList.retiredIgnoredAppsDefault.removing("com.bitwarden.desktop").adding("com.apple.TextEdit")
        settings.set(edited, for: SettingKeys.privacyIgnoredApps)

        settings.set(SettingKeys.privacyIgnoredApps.defaultValue, for: SettingKeys.privacyIgnoredApps)

        let list = settings.value(SettingKeys.privacyIgnoredApps).identifiers
        #expect(list.isEmpty)
        #expect(!list.contains("com.apple.TextEdit"))
    }

    // OC-8081 (settings half). An emptied list persists as empty (not reset to the defaults) across a relaunch.
    @Test func oc8081_emptiedListStaysEmpty() {
        let name = "flotsam.frd008.empty.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let reported = ReportedKeys()
        func launch() -> SettingsStore {
            SettingsStore(store: UserDefaultsStore(defaults: UserDefaults(suiteName: name)!), onInvalid: { reported.add($0) })
        }
        var list = launch().value(SettingKeys.privacyIgnoredApps)
        for id in Array(list.identifiers) { list = list.removing(id) }
        #expect(list.identifiers.isEmpty)

        launch().set(list, for: SettingKeys.privacyIgnoredApps)

        #expect(launch().value(SettingKeys.privacyIgnoredApps).identifiers.isEmpty, "empty is a valid list, not a corruption")
        #expect(reported.names.isEmpty, "no SET-DAT-001 for an empty list")
    }
}
