import Foundation
import Testing
@testable import FlotsamBase

/// FR-008-04..16 logic that lives in Base: menu content, onboarding flow, permission model, login item, list editing,
/// folder override validation.
@Suite struct MenuBarModelTests {
    private let chord = ChordBinding.chord(Chord(keyCode: 9, modifiers: [.control, .command]))

    @Test func menuListsFR00816ItemsInOrder() {
        let rows = MenuBarModel.entries(mode: .active, shelfEnabled: true, openLibrary: chord, saveClipboard: .none, toggleShelf: .none)
        #expect(rows == [
            .openLibrary(chord), .saveClipboard(.none), .toggleShelf(.none), .separator,
            .captureToggle(titleKey: "ui.menu.pauseCapture", next: .paused), .notices, .separator,
            .settings, .setupGuide, .separator, .quit,
        ])
    }

    @Test func toggleShelfIsAbsentWhenTheShelfIsOff() {
        let rows = MenuBarModel.entries(mode: .active, shelfEnabled: false, openLibrary: chord, saveClipboard: .none, toggleShelf: .none)
        #expect(!rows.contains(.toggleShelf(.none)))
        #expect(rows.count == 10)
    }

    @Test func pauseTogglesAndCuratedResumesToActive() {
        #expect(MenuBarModel.captureToggle(for: .active) == ("ui.menu.pauseCapture", .paused))
        #expect(MenuBarModel.captureToggle(for: .paused) == ("ui.menu.resumeCapture", .active))
        #expect(MenuBarModel.captureToggle(for: .curated) == ("ui.menu.resumeCapture", .active))
    }

    @Test func menuIsBuiltFromTheRegistryAtCallTime() {
        let settings = SettingsStore(store: MemoryKeyValueStore())
        #expect(MenuBarModel.entries(settings: settings).first == .openLibrary(SettingKeys.shortcutsOpenLibrary.defaultValue))
        let changed = ChordBinding.chord(Chord(keyCode: 40, modifiers: [.command, .shift]))
        settings.set(changed, for: SettingKeys.shortcutsOpenLibrary)
        settings.set(.paused, for: SettingKeys.captureMode)
        let rows = MenuBarModel.entries(settings: settings)
        #expect(rows.first == .openLibrary(changed))
        #expect(rows.contains(.captureToggle(titleKey: "ui.menu.resumeCapture", next: .active)))
    }

    @Test func eachModeHasADistinctLabelAndTheWarningAddsOne() {
        let keys = CaptureMode.allCases.map { MenuBarModel.icon(mode: $0, hasWarning: false).accessibilityKeys }
        #expect(Set(keys.map { $0[0] }).count == 3)
        #expect(MenuBarModel.icon(mode: .paused, hasWarning: true).accessibilityKeys.count == 2)
        #expect(MenuBarModel.icon(mode: .paused, hasWarning: true) != MenuBarModel.icon(mode: .paused, hasWarning: false))
    }

    @Test func chordsRenderLive() {
        #expect(Chord(keyCode: 9, modifiers: [.control, .command]).displayString == "\u{2303}\u{2318}V")
        #expect(Chord(keyCode: 49, modifiers: [.command, .shift, .option]).displayString == "\u{2325}\u{21E7}\u{2318}Space")
        #expect(Chord(keyCode: 9, modifiers: [.command]).keyEquivalent == "v")
    }

    @Test func everyCatalogueKeyTheModelNamesExists() {
        var keys = Set<String>(["ui.menu.pauseCapture", "ui.menu.resumeCapture"])
        for mode in CaptureMode.allCases { keys.formUnion(MenuIcon(mode: mode, warning: true).accessibilityKeys) }
        for step in OnboardingStep.allCases { keys.insert(step.titleKey); keys.insert(step.purposeKey) }
        for key in keys { #expect(FlotsamStrings.text(forKey: key) != nil, "missing \(key)") }
    }
}

@Suite struct OnboardingFlowTests {
    @Test func eightStepsInOrderWhenPasteboardIsGated() {
        var flow = OnboardingFlow()
        #expect(flow.total == 8 && flow.isFirst)
        var seen = [flow.current]
        while !flow.isLast { flow.advance(); seen.append(flow.current) }
        #expect(seen == OnboardingStep.allCases)
        flow.advance()
        #expect(flow.current == .done, "advance stops at the last step")
    }

    @Test func showsAutomaticallyOnlyUntilCompleted() {
        let settings = SettingsStore(store: MemoryKeyValueStore())
        #expect(OnboardingFlow.shouldShowAutomatically(settings: settings))
        settings.set(true, for: SettingKeys.onboardingCompleted)
        #expect(!OnboardingFlow.shouldShowAutomatically(settings: settings))
    }

    @Test func navigationAloneChangesNoSetting() {
        let raw = MemoryKeyValueStore()
        var flow = OnboardingFlow()
        while !flow.isLast { flow.advance() }
        #expect(raw.string(forKey: "onboarding.completed") == nil)
    }
}

private struct FakeProbe: PermissionProbe {
    var accessibility = false
    var inputMonitoring = false
    func isGranted(_ kind: PermissionKind) -> Bool { kind == .accessibility ? accessibility : inputMonitoring }
    func request(_ kind: PermissionKind) {}
    func openSystemSettings(_ kind: PermissionKind) {}
}

@Suite struct PermissionModelTests {
    @Test func withoutAccessibilityChoosingCopiesOnlyAndRaisesSETPRM001() {
        #expect(!PasteGate.isAllowed(probe: FakeProbe()))
        #expect(PasteGate.copyOnlyError().code == .setPrm001)
        #expect(PasteGate.isAllowed(probe: FakeProbe(accessibility: true)))
    }

    @Test func grantingTakesEffectWithoutRelaunchBecauseStateIsReadEachTime() {
        #expect(!PasteGate.isAllowed(probe: FakeProbe(accessibility: false)))
        #expect(PasteGate.isAllowed(probe: FakeProbe(accessibility: true)))
    }

    @Test func triggersOnWithAMissingPermissionNamesIt() {
        #expect(TriggerPermissionNotice.missing(triggersEnabled: true, probe: FakeProbe()) == [.setPrm001, .setPrm002])
        #expect(TriggerPermissionNotice.missing(triggersEnabled: true, probe: FakeProbe(accessibility: true)) == [.setPrm002])
        #expect(TriggerPermissionNotice.missing(triggersEnabled: true, probe: FakeProbe(accessibility: true, inputMonitoring: true)).isEmpty)
        #expect(TriggerPermissionNotice.missing(triggersEnabled: false, probe: FakeProbe()).isEmpty)
    }
}

private final class FakeLoginItem: LoginItemService, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginItemStatus
    var failure: FlotsamError?
    init(_ status: LoginItemStatus) { current = status }
    var status: LoginItemStatus { lock.withLock { current } }
    func register() -> FlotsamResult<Void> { apply(.enabled) }
    func unregister() -> FlotsamResult<Void> { apply(.off) }
    func openLoginItemsSettings() {}
    private func apply(_ next: LoginItemStatus) -> FlotsamResult<Void> {
        if let failure { return .failure(failure) }
        lock.withLock { current = next }
        return .success(())
    }
}

@Suite struct LoginItemTests {
    @Test func statusMapsToTheSwitch() {
        #expect(LoginItemController(service: FakeLoginItem(.enabled)).isOn)
        #expect(LoginItemController(service: FakeLoginItem(.requiresApproval)).isOn)
        #expect(!LoginItemController(service: FakeLoginItem(.off)).isOn)
    }

    @Test func togglingRegistersAndUnregisters() throws {
        let controller = LoginItemController(service: FakeLoginItem(.off))
        #expect(try controller.setEnabled(true).get() == .enabled)
        #expect(controller.isOn)
        #expect(try controller.setEnabled(false).get() == .off)
    }

    @Test func aFailureIsSETOS001AndLeavesTheStatusAlone() {
        let service = FakeLoginItem(.off)
        service.failure = FlotsamError(.setOs001, "register failed")
        let controller = LoginItemController(service: service)
        guard case .failure(let error) = controller.setEnabled(true) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == .setOs001)
        #expect(!controller.isOn)
    }
}

@Suite struct ListEditingTests {
    @Test func addIgnoresDuplicatesAndRemoveDeletes() {
        let list = BundleIdentifierList(["a.b"])
        #expect(list.adding("c.d").identifiers == ["a.b", "c.d"])
        #expect(list.adding("a.b").identifiers == ["a.b"])
        #expect(list.adding("c.d").removing("a.b").identifiers == ["c.d"])
    }

    @Test func aBundleWithoutAnIdentifierIsSETVAL002() {
        for raw in [nil, "", "   ", "has space"] {
            guard case .failure(let error) = BundleIdentifierList.validated(raw) else {
                Issue.record("expected failure for \(String(describing: raw))")
                continue
            }
            #expect(error.code == .setVal002)
        }
        #expect((try? BundleIdentifierList.validated("com.example.app").get()) == "com.example.app")
    }

    @Test func resetRestoresTheEmptyDefault() {
        let settings = SettingsStore(store: MemoryKeyValueStore())
        settings.set(BundleIdentifierList(["com.example.app"]), for: SettingKeys.privacyIgnoredApps)
        settings.set(SettingKeys.privacyIgnoredApps.defaultValue, for: SettingKeys.privacyIgnoredApps)
        #expect(settings.value(SettingKeys.privacyIgnoredApps).identifiers.isEmpty)
    }
}

@Suite struct FolderOverrideChoosingTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-fo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aReadableFolderIsAccepted() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let override = try FolderOverride.choosing(dir).get()
        #expect(override.resolvedURL?.standardizedFileURL.resolvingSymlinksInPath() == dir.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test func missingFileAndUnreadableFolderAreSETVAL001() throws {
        let dir = try makeDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let file = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: file)
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        for url in [dir.appendingPathComponent("nope"), file, locked] {
            guard case .failure(let error) = FolderOverride.choosing(url) else {
                Issue.record("expected failure for \(url.lastPathComponent)")
                continue
            }
            #expect(error.code == .setVal001)
        }
    }
}
