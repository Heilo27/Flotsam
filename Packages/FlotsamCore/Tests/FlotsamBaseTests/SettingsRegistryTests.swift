import Foundation
import Testing
@testable import FlotsamBase

/// FR-008-01 / FR-008-02 (AC-008-01, AC-008-02). Expected names, types and defaults are literals from the FR-008-01 table.
@Suite struct SettingsRegistryTests {
    @Test func registryEqualsTheFRTable() {
        let expected: [(String, String, String)] = [
            ("capture.mode", "CaptureMode", "active"),
            ("screenshots.enabled", "Bool", "true"),
            ("screenshots.folderOverride", "FolderOverride", ""),
            ("shelf.enabled", "Bool", "true"),
            ("shelf.placement", "ShelfPlacement", "rightEdge"),
            ("shelf.revealOnEdgeHover", "Bool", "false"),
            ("shortcuts.openLibrary", "ChordBinding", "9:3"),
            ("shortcuts.saveClipboard", "ChordBinding", "none"),
            ("shortcuts.toggleShelf", "ChordBinding", "none"),
            ("triggers.enabled", "Bool", "true"),
            ("triggers.excludedApps", "BundleIdentifierList", BundleIdentifierList.defaultTriggerExcludedApps.persisted),
            ("privacy.ignoredApps", "BundleIdentifierList", BundleIdentifierList.defaultIgnoredApps.persisted),
            ("storage.retention", "RetentionPreset", "d30"),
            ("storage.imageBudget", "ImageBudget", "gib2"),
            ("storage.imageQuality", "ImageQuality", "original"),
            ("library.sort", "LibrarySort", "recent"),
            ("library.viewMode", "LibraryViewMode", "list"),
            ("library.panelSize", "PanelSize", "760.0x480.0"),
            ("onboarding.completed", "Bool", "false"),
            ("settings.lastPane", "SettingsPane", "general"),
        ]
        let actual = SettingKeys.all.map { ($0.name, $0.valueType, $0.defaultPersisted) }
        #expect(actual.count == expected.count)
        for (a, e) in zip(actual, expected) { #expect(a == e, "row \(e.0)") }
        #expect(Set(SettingKeys.all.map(\.name)).count == SettingKeys.all.count, "no duplicate key")
        #expect(SettingKeys.all.allSatisfy { !$0.owner.isEmpty })
    }

    @Test func defaultIgnoredAppsAreTheSixFromFR00811() {
        #expect(BundleIdentifierList.defaultIgnoredApps.identifiers == [
            "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
            "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
        ])
    }

    @Test func everyTypeRoundTripsThroughItsPersistedForm() {
        let store = SettingsStore(store: MemoryKeyValueStore())
        store.set(false, for: SettingKeys.shelfEnabled)
        #expect(store.value(SettingKeys.shelfEnabled) == false)
        store.set(.chord(Chord(keyCode: 40, modifiers: [.command, .shift])), for: SettingKeys.shortcutsSaveClipboard)
        #expect(store.value(SettingKeys.shortcutsSaveClipboard) == .chord(Chord(keyCode: 40, modifiers: [.command, .shift])))
        store.set(.none, for: SettingKeys.shortcutsOpenLibrary)
        #expect(store.value(SettingKeys.shortcutsOpenLibrary) == .none)
        store.set(BundleIdentifierList(["a.b", "c.d"]), for: SettingKeys.privacyIgnoredApps)
        #expect(store.value(SettingKeys.privacyIgnoredApps).identifiers == ["a.b", "c.d"])
        store.set(BundleIdentifierList([]), for: SettingKeys.privacyIgnoredApps)
        #expect(store.value(SettingKeys.privacyIgnoredApps).identifiers == [], "an emptied list stays empty, not the defaults")
        store.set(PanelSize(width: 900, height: 600), for: SettingKeys.libraryPanelSize)
        #expect(store.value(SettingKeys.libraryPanelSize) == PanelSize(width: 900, height: 600))
        store.set(.about, for: SettingKeys.settingsLastPane)
        #expect(store.value(SettingKeys.settingsLastPane) == .about)
        store.set(.mostUsed, for: SettingKeys.librarySort)
        #expect(store.value(SettingKeys.librarySort) == .mostUsed)
        store.set(.bookmark(Data([1, 2, 3])), for: SettingKeys.screenshotsFolderOverride)
        // a bookmark that does not resolve is invalid data (AC-008-02), so it reads back as none
        #expect(store.value(SettingKeys.screenshotsFolderOverride) == .none)
    }

    @Test func validBookmarkSurvives() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-bm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try dir.bookmarkData(options: [.withSecurityScope])
        let store = SettingsStore(store: MemoryKeyValueStore())
        store.set(.bookmark(data), for: SettingKeys.screenshotsFolderOverride)
        #expect(store.value(SettingKeys.screenshotsFolderOverride) == .bookmark(data))
    }

    @Test func invalidStoredValuesFallBackToTheDefaultAndReportOncePerKey() {
        let raw = MemoryKeyValueStore()
        let reported = ReportedKeys()
        let store = SettingsStore(store: raw, onInvalid: { reported.add($0) })

        raw.setString("fortnight", forKey: "storage.retention")
        #expect(store.value(SettingKeys.storageRetention) == .d30)
        #expect(raw.string(forKey: "storage.retention") == "d30", "the bad value is replaced by the default (OC-8011)")
        raw.setString("fortnight", forKey: "storage.retention")
        #expect(store.value(SettingKeys.storageRetention) == .d30)
        #expect(reported.names == ["storage.retention"], "second corruption of the same key is not reported again")

        raw.setString("maybe", forKey: "shelf.enabled")
        raw.setString("1:0", forKey: "shortcuts.openLibrary")  // no ⌘ or ⌃: no recorder could have produced it
        raw.setString("[\"has space\"]", forKey: "privacy.ignoredApps")
        raw.setString("0x480", forKey: "library.panelSize")
        raw.setString("!!not base64!!", forKey: "screenshots.folderOverride")
        #expect(store.value(SettingKeys.shelfEnabled) == true)
        #expect(store.value(SettingKeys.shortcutsOpenLibrary) == SettingKeys.shortcutsOpenLibrary.defaultValue)
        #expect(store.value(SettingKeys.privacyIgnoredApps) == .defaultIgnoredApps)
        #expect(store.value(SettingKeys.libraryPanelSize) == PanelSize(width: 760, height: 480))
        #expect(store.value(SettingKeys.screenshotsFolderOverride) == .none)
        #expect(Set(reported.names) == [
            "storage.retention", "shelf.enabled", "shortcuts.openLibrary", "privacy.ignoredApps", "library.panelSize",
            "screenshots.folderOverride",
        ])
        #expect(reported.names.count == 6)
    }

    /// AC-008-01 source scan: every `SettingKey(` declaration in Sources/ is in the registry, and the registry is `all`.
    @Test func everyDeclaredKeyIsInTheRegistryList() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var declared = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            declared += text.components(separatedBy: "= SettingKey(").count - 1
        }
        #expect(declared == SettingKeys.all.count)
    }

    @Test func absentValueIsNotReported() {
        let reported = ReportedKeys()
        let store = SettingsStore(store: MemoryKeyValueStore(), onInvalid: { reported.add($0) })
        _ = store.value(SettingKeys.captureMode)
        #expect(reported.names.isEmpty)
    }

    @Test func changesAreDeliveredInlineAndWithoutRelaunch() async {
        let store = SettingsStore(store: MemoryKeyValueStore())
        let seen = ReportedKeys()
        let unsubscribe = store.subscribe { seen.add("\($0.name)=\($0.persisted)") }
        store.set(.paused, for: SettingKeys.captureMode)
        #expect(seen.names == ["capture.mode=paused"], "delivered before set returns")
        unsubscribe()
        store.set(.active, for: SettingKeys.captureMode)
        #expect(seen.names.count == 1, "unsubscribed handlers hear nothing")

        let stream = store.changes(of: SettingKeys.storageRetention)
        store.set(.curated, for: SettingKeys.captureMode)  // another key: not delivered to this stream
        store.set(.y1, for: SettingKeys.storageRetention)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .y1)
    }
}

final class ReportedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ name: String) { lock.withLock { values.append(name) } }
    var names: [String] { lock.withLock { values } }
}
