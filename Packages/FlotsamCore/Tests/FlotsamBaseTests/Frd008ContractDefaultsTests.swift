import Foundation
import Testing
@testable import FlotsamBase

/// FRD-008 contract tests, oracle OC-8001...OC-8022 (defaults, recovery, live application, persistence).
/// Every expected value is a literal from `.claude/oracle/frd-008-contract.json`. Every store is a UserDefaults suite
/// with a unique name that is removed afterwards: the app's own preferences domain is never opened.
/// A contract the code does not meet is kept in the suite inside `withKnownIssue("DEFECT ...")` so it is reported and
/// turns red the day it is fixed (the known issue then goes unrecorded and the test fails until the wrapper is removed).
@Suite struct Frd008ContractDefaultsTests {
    /// One isolated preferences domain. `reopen()` builds a fresh `SettingsStore` over the same domain, which is what a
    /// relaunch is.
    struct Domain {
        let suite = TestDefaultsSuite("frd008.contract")
        let reported = ReportedKeys()
        var name: String { suite.name }
        var defaults: UserDefaults { suite.defaults }

        func reopen() -> SettingsStore {
            let reported = self.reported
            return SettingsStore(store: UserDefaultsStore(defaults: defaults), onInvalid: { reported.add($0) })
        }

        /// What `defaults read` would show for a key.
        func onDisk(_ key: String) -> String? { defaults.string(forKey: key) }
        func poke(_ value: String, _ key: String) { defaults.set(value, forKey: key) }
        func remove() { suite.remove() }
    }

    // MARK: - Defaults

    // OC-8001. Given a fresh install. When General is opened. Then the shelf and screenshot rows read their defaults.
    @Test func oc8001_generalDefaults() {
        let domain = Domain(); defer { domain.remove() }
        let settings = domain.reopen()

        #expect(settings.value(SettingKeys.screenshotsEnabled) == true)
        #expect(settings.value(SettingKeys.screenshotsFolderOverride) == FolderOverride.none)
        #expect(SettingsString.folderSystemDefault.text == "System default")
        #expect(settings.value(SettingKeys.shelfEnabled) == true)
        #expect(settings.value(SettingKeys.shelfPlacement) == .rightEdge)
        #expect(SettingsString.placementRightEdge.text == "Right edge")
        #expect(settings.value(SettingKeys.shelfRevealOnEdgeHover) == false)
        #expect(SettingsString.pickUpScreenshots.text == "Pick up screenshots")
        #expect(SettingsString.revealAtEdge.text == "Reveal on edge hover")
        #expect(domain.reported.names.isEmpty, "defaults are not corruption: nothing is reported")
    }

    // OC-8001 (label). The row reads 'Launch at login'.
    @Test func oc8001_launchAtLoginLabel() {
        #expect(SettingsString.launchAtLogin.text == "Launch at login")
    }

    // OC-8002. Given a fresh install. Then capture mode is Active, the menu offers Pause Capture, and automatic capture is on.
    @Test func oc8002_captureModeActiveAndMenuOffersPause() {
        let domain = Domain(); defer { domain.remove() }
        let mode = domain.reopen().value(SettingKeys.captureMode)

        #expect(mode == .active)
        #expect(SettingsString.modeActive.text == "Active")
        #expect(MenuBarModel.captureToggle(for: mode).titleKey == "ui.menu.pauseCapture")
        #expect(FlotsamStrings.text(forKey: "ui.menu.pauseCapture") == "Pause Capture")
        #expect(mode.capturesClipboardAutomatically, "a copy is saved: the capture half of the +1 count")
    }

    // OC-8003. Given a fresh install. Then Open Library is bound to control-command-V and the other two are unbound.
    @Test func oc8003_shortcutDefaults() {
        let domain = Domain(); defer { domain.remove() }
        let settings = domain.reopen()

        guard case .chord(let chord) = settings.value(SettingKeys.shortcutsOpenLibrary) else {
            Issue.record("Open Library must be bound by default"); return
        }
        #expect(chord.displayString == "\u{2303}\u{2318}V")
        #expect(settings.value(SettingKeys.shortcutsSaveClipboard) == ChordBinding.none)
        #expect(settings.value(SettingKeys.shortcutsToggleShelf) == ChordBinding.none)
        #expect(SettingsString.shortcutNotSet.text == "Not set")
    }

    // OC-8004. Given a fresh install. Then Expand typed triggers is on and the excluded list is exactly the 11.
    @Test func oc8004_triggerDefaults() {
        let domain = Domain(); defer { domain.remove() }
        let settings = domain.reopen()
        let expected: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
            "io.alacritty", "dev.warp.Warp-Stable", "co.zeit.hyper", "com.microsoft.rdc.macos",
            "com.apple.ScreenSharing", "com.parallels.desktop.console", "com.vmware.fusion",
        ]

        let identifiers = settings.value(SettingKeys.triggersExcludedApps).identifiers
        #expect(settings.value(SettingKeys.triggersEnabled) == true)
        #expect(identifiers.count == 11, "exactly 11 entries, no duplicates")
        #expect(Set(identifiers) == expected)
        #expect(SettingsString.expandTriggers.text == "Expand typed triggers")
    }

    // OC-8005. Given a fresh install. Then Storage reads 30 days, 2 GB, Original.
    @Test func oc8005_storageDefaults() {
        let domain = Domain(); defer { domain.remove() }
        let settings = domain.reopen()

        #expect(settings.value(SettingKeys.storageRetention) == .d30)
        #expect(SettingsString.retention30Days.text == "30 days")
        #expect(settings.value(SettingKeys.storageImageBudget) == .gib2)
        #expect(SettingsString.budget2GB.text == "2 GB")
        #expect(settings.value(SettingKeys.storageImageQuality) == .original)
        #expect(SettingsString.qualityOriginal.text == "Original")
        #expect(SettingsString.keepHistoryFor.text == "Keep history for")
        #expect(SettingsString.imageLimit.text == "Image storage limit")
    }

    // OC-8006. Given a fresh install. Then the Library is 760 x 480, List, most-recent-first.
    @Test func oc8006_libraryDefaults() {
        let domain = Domain(); defer { domain.remove() }
        let settings = domain.reopen()
        let size = settings.value(SettingKeys.libraryPanelSize)

        #expect(size.width == 760)
        #expect(size.height == 480)
        #expect(settings.value(SettingKeys.libraryViewMode) == .list)
        #expect(settings.value(SettingKeys.librarySort) == .recent)
    }

    // OC-8007. Given no preferences domain. Then onboarding shows by itself and Settings opens on General.
    @Test func oc8007_firstLaunchShowsOnboardingAndGeneral() {
        let domain = Domain(); defer { domain.remove() }
        let settings = domain.reopen()

        #expect(OnboardingFlow.shouldShowAutomatically(settings: settings) == true)
        #expect(SettingsPane.lastOpened(in: settings) == .general)
        #expect(SettingsString.paneGeneral.text == "General")

        // Negative: once onboarding is completed the window no longer opens itself.
        settings.set(true, for: SettingKeys.onboardingCompleted)
        #expect(OnboardingFlow.shouldShowAutomatically(settings: domain.reopen()) == false)
    }

    // OC-8008. Deleting the preferences domain resets only registry values. Item data and the screenshot watermark are
    // not in preferences, so the registry must not hold a key for either. Launch at login is not a registry value.
    @Test func oc8008_preferencesDeleteTouchesRegistryOnly() {
        let names = SettingKeys.all.map(\.name)

        #expect(!names.contains { $0.contains("login") || $0.contains("launch") }, "launch at login is not a registry value")
        #expect(!names.contains { $0.contains("lastScan") || $0.contains("watermark") }, "the scan watermark is database state")
        #expect(!names.contains { $0.contains("history") || $0.contains("items") }, "item data is database state")
        #expect(names.count == 36)
    }

    // OC-8009. The registry is exactly the 36 keys of the FR-008-01 table, and each key name is spelled once in production code.
    @Test func oc8009_registryIsTheThirtyThreeKeysAndNothingReadsDefaultsAroundIt() throws {
        let expected: [String: (type: String, def: String)] = [
            "capture.mode": ("CaptureMode", "active"), "screenshots.enabled": ("Bool", "true"),
            "screenshots.folderOverride": ("FolderOverride", ""), "shelf.enabled": ("Bool", "true"),
            "shelf.placement": ("ShelfPlacement", "rightEdge"), "shelf.revealOnEdgeHover": ("Bool", "false"),
            "shortcuts.openLibrary": ("ChordBinding", "9:3"), "shortcuts.saveClipboard": ("ChordBinding", "none"),
            "shortcuts.toggleShelf": ("ChordBinding", "none"), "triggers.enabled": ("Bool", "true"),
            "storage.retention": ("RetentionPreset", "d30"), "storage.imageBudget": ("ImageBudget", "gib2"),
            "storage.imageQuality": ("ImageQuality", "original"), "library.sort": ("LibrarySort", "recent"),
            "library.viewMode": ("LibraryViewMode", "list"), "library.panelSize": ("PanelSize", "760.0x480.0"),
            "library.layout": ("LibraryLayoutMode", "standard"), "library.compactPanelSize": ("PanelSize", "520.0x520.0"),
            "onboarding.completed": ("Bool", "false"), "settings.lastPane": ("SettingsPane", "general"),
            "capture.autoBundle": ("Bool", "true"), "capture.cue": ("Bool", "true"), "shelf.edgeBar": ("Bool", "false"),
            "shortcuts.addClip": ("ChordBinding", "none"), "shortcuts.pasteQueue": ("ChordBinding", "none"),
            "library.background": ("LibraryBackground", "system"), "library.previewPreset": ("LibraryPreviewPreset", "closed"),
            "library.closeAfterPaste": ("Bool", "true"), "library.resumeOnReopen": ("Bool", "false"),
            "library.display": ("LibraryDisplay", "pointer"), "library.types": ("TypeOrder", TypeOrder.default.persisted),
            "library.sidebarTypesCollapsed": ("Bool", "false"), "library.sidebarTagsCollapsed": ("Bool", "true"),
            "library.sidebarAppsCollapsed": ("Bool", "true"),
        ]
        let all = SettingKeys.all
        #expect(all.count == 36)
        for (name, row) in expected {
            let descriptor = all.first { $0.name == name }
            #expect(descriptor?.valueType == row.type, "type of \(name)")
            #expect(descriptor?.defaultPersisted == row.def, "default of \(name)")
        }
        #expect(Set(all.map(\.name)).isSuperset(of: ["triggers.excludedApps", "privacy.ignoredApps"]))

        // Source scan: no UserDefaults / @AppStorage in code outside the one adapter; each key literal appears once.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var code: [(file: String, line: String)] = []
        for folder in ["Packages/FlotsamCore/Sources", "App"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.hasPrefix("//") { code.append((url.lastPathComponent, String(line))) }
                }
            }
        }
        #expect(code.count > 1000, "the scan really read the sources (found \(code.count) lines)")
        let stray = code.filter { ($0.line.contains("UserDefaults") || $0.line.contains("@AppStorage")) && $0.file != "Adapters.swift" }
        #expect(stray.isEmpty, "UserDefaults used outside the adapter: \(stray.map(\.file))")
        for key in all.map(\.name) {
            let literal = "\"\(key)\""
            let uses = code.filter { $0.line.contains(literal) }.count
            #expect(uses == 1, "key literal \(literal) must be spelled exactly once, found \(uses)")
        }
    }

    // OC-8010. Each default equals the owner FR's stated default.
    @Test func oc8010_defaultsEqualTheOwnerFRs() {
        let domain = Domain(); defer { domain.remove() }
        let settings = domain.reopen()

        #expect(settings.value(SettingKeys.captureMode) == .active)  // FR-007-12
        #expect(settings.value(SettingKeys.storageRetention) == .d30)  // FR-007-09
        #expect(settings.value(SettingKeys.triggersEnabled) == true)  // FR-005-10
        #expect(settings.value(SettingKeys.triggersExcludedApps).identifiers.count == 11)  // FR-005-13
        #expect(settings.value(SettingKeys.screenshotsEnabled) == true)  // FR-002-05
        #expect(SettingKeys.all.first { $0.name == "capture.mode" }?.owner == "FR-007-12")
        #expect(SettingKeys.all.first { $0.name == "storage.retention" }?.owner == "FR-007-09")
        #expect(SettingKeys.all.first { $0.name == "triggers.enabled" }?.owner == "FR-005-10")
    }

    // MARK: - Recovery from invalid stored values

    // OC-8011. retention 'd45' -> 30 days, rewritten to d30 on disk, exactly one SET-DAT-001, and its text.
    @Test func oc8011_invalidRetentionResetsAndReportsOnce() {
        let domain = Domain(); defer { domain.remove() }
        domain.poke("d45", "storage.retention")
        let settings = domain.reopen()

        #expect(settings.value(SettingKeys.storageRetention) == .d30)
        #expect(domain.onDisk("storage.retention") != "d45", "the bad value must not be left behind")
        #expect(domain.reported.names == ["storage.retention"], "exactly one report")
        #expect(FlotsamStrings.text(forKey: "error.SET-DAT-001") == "A setting had an invalid value and was reset to its default.")
        #expect(FlotsamError(.setDat001, "x").code == .setDat001)
    }

    // OC-8011 (rewrite). `defaults read` shows d30 after recovery: the registry writes the default back.
    @Test func oc8011_diskValueAfterRecoveryIsD30() {
        let domain = Domain(); defer { domain.remove() }
        domain.poke("d45", "storage.retention")
        _ = domain.reopen().value(SettingKeys.storageRetention)

        #expect(domain.onDisk("storage.retention") == "d30")
    }

    // OC-8012. Reading the invalid key many times reports once; a relaunch (fresh store) reports nothing more.
    @Test func oc8012_reportedOncePerLaunchThenQuiet() {
        let domain = Domain(); defer { domain.remove() }
        domain.poke("d45", "storage.retention")
        let launch1 = domain.reopen()

        for _ in 0..<5 { #expect(launch1.value(SettingKeys.storageRetention) == .d30) }
        #expect(domain.reported.names.count == 1, "five Storage opens, still one report")

        let before = domain.reported.names.count
        let launch2 = domain.reopen()
        #expect(launch2.value(SettingKeys.storageRetention) == .d30)
        #expect(domain.reported.names.count == before, "after relaunch the recovered value raises nothing")
    }

    // OC-8013. 'maybe' for a Bool -> default true, one report.
    @Test func oc8013_wrongTypeBoolRecovers() {
        let domain = Domain(); defer { domain.remove() }
        domain.poke("maybe", "shelf.enabled")
        let settings = domain.reopen()

        #expect(settings.value(SettingKeys.shelfEnabled) == true)
        #expect(domain.reported.names == ["shelf.enabled"])
    }

    // OC-8014. Unknown enum case 'topEdge' -> Right Edge, one report.
    @Test func oc8014_unknownEnumCaseRecovers() {
        let domain = Domain(); defer { domain.remove() }
        domain.poke("topEdge", "shelf.placement")
        let settings = domain.reopen()

        #expect(settings.value(SettingKeys.shelfPlacement) == .rightEdge)
        #expect(domain.reported.names == ["shelf.placement"])
        #expect(ShelfPlacement(persisted: "topEdge") == nil, "topEdge is not a case")
    }

    // OC-8015. Bytes that are not a bookmark -> system default folder, one report.
    @Test func oc8015_invalidBookmarkFallsBackToSystemDefault() {
        let domain = Domain(); defer { domain.remove() }
        domain.poke(Data("not a bookmark at all".utf8).base64EncodedString(), "screenshots.folderOverride")
        let settings = domain.reopen()

        let folder = settings.value(SettingKeys.screenshotsFolderOverride)
        #expect(folder == FolderOverride.none)
        #expect(folder.resolvedURL == nil, "no folder is watched from the junk bookmark")
        #expect(domain.reported.names == ["screenshots.folderOverride"])
    }

    // TASK-458. A bookmark made without `.withSecurityScope` (what a launch-argument or script-made bookmark usually is)
    // is a real bookmark but not the stored form FR-008-10 specifies, so it reads as none with one SET-DAT-001 report.
    // The same folder chosen through the app's own path (`FolderOverride.choosing`) is usable.
    @Test func task458_bookmarkWithoutSecurityScopeIsRejectedAppMadeOneIsUsable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam.task458.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let unscoped = try folder.bookmarkData()
        let rejected = Domain(); defer { rejected.remove() }
        rejected.poke(unscoped.base64EncodedString(), "screenshots.folderOverride")
        #expect(rejected.reopen().value(SettingKeys.screenshotsFolderOverride) == FolderOverride.none)
        #expect(rejected.reported.names == ["screenshots.folderOverride"])

        let accepted = Domain(); defer { accepted.remove() }
        guard case .success(let chosen) = FolderOverride.choosing(folder) else { Issue.record("folder must be accepted"); return }
        accepted.poke(chosen.persisted, "screenshots.folderOverride")
        let value = accepted.reopen().value(SettingKeys.screenshotsFolderOverride)
        #expect(value.resolvedURL?.lastPathComponent == folder.lastPathComponent)
        #expect(accepted.reported.names.isEmpty)
    }

    // OC-8016. Key code 9999 with control and command held. The chord is unusable, so Open Library must return to the
    // default and be reported once.
    @Test func oc8016_unusableChordFallsBackToDefault() {
        let domain = Domain(); defer { domain.remove() }
        domain.poke("9999:3", "shortcuts.openLibrary")
        let settings = domain.reopen()

        guard case .chord(let chord) = settings.value(SettingKeys.shortcutsOpenLibrary) else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.keyCode == 9)
        #expect(chord.displayString == "\u{2303}\u{2318}V")
        #expect(domain.reported.names == ["shortcuts.openLibrary"])
    }

    // OC-8016 (negative control). A chord with no command or control is unusable and does recover, so the reset path
    // for shortcuts itself works.
    @Test func oc8016_chordWithoutCommandOrControlRecovers() {
        let domain = Domain(); defer { domain.remove() }
        domain.poke("9:0", "shortcuts.openLibrary")
        let settings = domain.reopen()

        #expect(settings.value(SettingKeys.shortcutsOpenLibrary).persisted == "9:3")
        #expect(domain.reported.names == ["shortcuts.openLibrary"])
    }

    // OC-8017. Two invalid keys both recover and at least one report is raised.
    @Test func oc8017_twoInvalidKeysBothRecover() {
        let domain = Domain(); defer { domain.remove() }
        domain.poke("d45", "storage.retention")
        domain.poke("topEdge", "shelf.placement")
        let settings = domain.reopen()

        #expect(settings.value(SettingKeys.storageRetention) == .d30)
        #expect(settings.value(SettingKeys.shelfPlacement) == .rightEdge)
        #expect(Set(domain.reported.names) == ["storage.retention", "shelf.placement"])
        #expect(domain.reported.names.count >= 1)
    }

    // MARK: - Live application and persistence

    // OC-8018. A placement change reaches subscribers before set returns and with no relaunch, and reads back at once.
    @Test func oc8018_placementChangeAppliesWithoutRelaunch() {
        let domain = Domain(); defer { domain.remove() }
        let settings = domain.reopen()
        let seen = ReportedKeys()
        _ = settings.subscribe { seen.add("\($0.name)=\($0.persisted)") }

        settings.set(.leftEdge, for: SettingKeys.shelfPlacement)

        #expect(seen.names == ["shelf.placement=leftEdge"], "one change, delivered inline")
        #expect(settings.value(SettingKeys.shelfPlacement) == .leftEdge)
    }

    // OC-8019. Pausing in Settings flips the menu to Resume Capture and stops automatic capture with no relaunch.
    @Test func oc8019_pauseAppliesToMenuAndCaptureImmediately() {
        let domain = Domain(); defer { domain.remove() }
        let settings = domain.reopen()
        #expect(settings.value(SettingKeys.captureMode).capturesClipboardAutomatically)

        settings.set(.paused, for: SettingKeys.captureMode)

        let mode = settings.value(SettingKeys.captureMode)
        #expect(mode == .paused)
        #expect(mode.capturesClipboardAutomatically == false, "a copy while paused adds nothing: delta 0")
        #expect(mode.importsScreenshots == false)
        #expect(MenuBarModel.captureToggle(for: mode).titleKey == "ui.menu.resumeCapture")
        #expect(FlotsamStrings.text(forKey: "ui.menu.resumeCapture") == "Resume Capture")
        #expect(MenuBarModel.icon(mode: mode, hasWarning: false).accessibilityKeys == ["ui.menu.iconPaused"])
        #expect(MenuBarModel.captureToggle(for: .active).titleKey == "ui.menu.pauseCapture", "active still offers Pause")
    }

    // OC-8020. Placement, view mode and last pane survive a relaunch (a fresh store over the same domain).
    @Test func oc8020_preferencesSurviveRelaunch() {
        let domain = Domain(); defer { domain.remove() }
        let first = domain.reopen()
        first.set(.bottomEdge, for: SettingKeys.shelfPlacement)
        first.set(.grid, for: SettingKeys.libraryViewMode)
        SettingsPane.privacy.remember(in: first)

        let second = domain.reopen()
        #expect(second.value(SettingKeys.shelfPlacement) == .bottomEdge)
        #expect(SettingsString.placementBottomEdge.text == "Bottom edge")
        #expect(second.value(SettingKeys.libraryViewMode) == .grid)
        #expect(SettingsPane.lastOpened(in: second) == .privacy)
        #expect(second.value(SettingKeys.storageRetention) == .d30, "untouched keys stay at their defaults")
        #expect(domain.reported.names.isEmpty)
    }

    // OC-8021. A database reset (STO-DB-002) is a database event: nothing in the registry is keyed to the database, so
    // preferences cannot be changed by it. Checked from the registry side: no key names item or database state.
    @Test func oc8021_preferencesAreIndependentOfTheDatabase() {
        let domain = Domain(); defer { domain.remove() }
        let first = domain.reopen()
        first.set(.leftEdge, for: SettingKeys.shelfPlacement)
        first.set(.d90, for: SettingKeys.storageRetention)

        // The damaged-database relaunch touches no preference: a fresh store still reads both values.
        let second = domain.reopen()
        #expect(second.value(SettingKeys.shelfPlacement) == .leftEdge)
        #expect(second.value(SettingKeys.storageRetention) == .d90)
        #expect(SettingKeys.all.allSatisfy { !$0.name.contains("database") && !$0.name.contains("db") })
    }

    // OC-8022. There is no export, import or sync control: the panes, menu entries and string catalogue have none.
    @Test func oc8022_noExportImportOrSyncControl() {
        let domain = Domain(); defer { domain.remove() }
        let entries = MenuBarModel.entries(settings: domain.reopen())
        let forbidden = ["export", "import", "sync", "icloud"]

        let titles = SettingsPane.allCases.map { $0.title.text.lowercased() }
        #expect(titles == ["general", "library", "shortcuts", "types", "triggers", "privacy", "storage", "tips", "about"])
        for word in forbidden {
            #expect(!titles.contains { $0.contains(word) }, "pane title mentions \(word)")
            // The two exceptions are not settings transfer: .clearDone is a deletion message, and .importRecentScreenshots
            // is FRD-002 FR-002-12's screenshot backfill button, required in Settings (it moves no settings).
            #expect(!SettingsString.allCases.contains {
                $0.text.lowercased().contains(word) && $0 != .clearDone && $0 != .importRecentScreenshots },
                    "a Settings string mentions \(word)")
        }
        let rows = entries.filter { $0 != .separator }
        #expect(rows.count == 10, "ten actionable rows (4 shortcuts, the pause or resume row, clear recent, recent problems, settings, setup guide, quit); none transfers settings")
    }
}
