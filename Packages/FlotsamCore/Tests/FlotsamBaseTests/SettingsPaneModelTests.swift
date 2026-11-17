import Foundation
import Testing
@testable import FlotsamBase

private struct StubProbe: PermissionProbe {
    let granted: Set<String>
    func isGranted(_ kind: PermissionKind) -> Bool { granted.contains("\(kind)") }
    func request(_ kind: PermissionKind) {}
    func openSystemSettings(_ kind: PermissionKind) {}
}

@Suite struct SettingsPaneModelTests {
    @Test func panesAreInTheFRD008Order() {
        #expect(SettingsPane.allCases == [.general, .shortcuts, .triggers, .privacy, .storage, .about])
        #expect(SettingsPane.allCases.map(\.title) == [
            .paneGeneral, .paneShortcuts, .paneTriggers, .panePrivacy, .paneStorage, .paneAbout,
        ])
        #expect(SettingsPane.allCases.map(\.symbolName) == [
            "gearshape", "keyboard", "bolt", "hand.raised", "internaldrive", "info.circle",
        ])
    }

    @Test func reopensOnTheLastPane() {
        let settings = SettingsStore(store: MemoryKeyValueStore())
        #expect(SettingsPane.lastOpened(in: settings) == .general)
        SettingsPane.privacy.remember(in: settings)
        #expect(SettingsPane.lastOpened(in: settings) == .privacy)
    }

    @Test func aStoredPaneThatIsNotAPaneReopensOnGeneral() {
        let store = MemoryKeyValueStore()
        store.setString("advanced", forKey: SettingKeys.settingsLastPane.name)
        #expect(SettingsPane.lastOpened(in: SettingsStore(store: store)) == .general)
    }

    @Test func revealAtEdgeIsOffWhenShelfIsOffOrInTheMenuBar() {
        #expect(ShelfRevealRule.isEnabled(shelfEnabled: true, placement: .rightEdge))
        #expect(ShelfRevealRule.isEnabled(shelfEnabled: true, placement: .bottomEdge))
        #expect(!ShelfRevealRule.isEnabled(shelfEnabled: true, placement: .menuBar))
        #expect(!ShelfRevealRule.isEnabled(shelfEnabled: false, placement: .rightEdge))
    }

    @Test func loginItemRowFollowsTheStatusMacOSReports() {
        let enabled = LoginItemPresentation(status: .enabled)
        #expect(enabled.isOn && enabled.caption == nil && !enabled.showsLoginItemsButton)
        let pending = LoginItemPresentation(status: .requiresApproval)
        #expect(pending.isOn && pending.caption == .loginApprovalCaption && pending.showsLoginItemsButton)
        let off = LoginItemPresentation(status: .off)
        #expect(!off.isOn && off.caption == nil && !off.showsLoginItemsButton)
    }

    @Test func permissionRowsReadTheProbeFreshEachTime() {
        let rows = PermissionRow.current(probe: StubProbe(granted: ["accessibility"]))
        #expect(rows.map(\.kind) == [.accessibility, .inputMonitoring])
        #expect(rows.map(\.isGranted) == [true, false])
        #expect(rows.map(\.status) == [.permissionGranted, .permissionNotGranted])
        #expect(PermissionRow.current(probe: StubProbe(granted: [])).allSatisfy { !$0.isGranted })
    }

    @Test func onlyAShorterRetentionCanDeleteSoOnlyItAsks() {
        #expect(RetentionPreset.d7.isShorter(than: .d30))
        #expect(RetentionPreset.y1.isShorter(than: .forever))
        #expect(!RetentionPreset.d30.isShorter(than: .d30))
        #expect(!RetentionPreset.forever.isShorter(than: .d7))
        #expect(StorageChangeFlow.needsPreview(retention: .d7, from: .forever))
        #expect(!StorageChangeFlow.needsPreview(retention: .forever, from: .d7))
    }

    @Test func retentionPresetsAreDeclaredShortestFirst() {
        #expect(RetentionPreset.allCases == [.d7, .d30, .d90, .y1, .forever])
        #expect(ImageBudget.allCases == [.mib500, .gib2, .gib10, .unlimited])
    }

    @Test func onlyALowerImageBudgetCanDeleteSoOnlyItAsks() {
        #expect(ImageBudget.mib500.isLower(than: .gib2))
        #expect(ImageBudget.gib10.isLower(than: .unlimited))
        #expect(!ImageBudget.gib2.isLower(than: .gib2))
        #expect(!ImageBudget.unlimited.isLower(than: .mib500))
        #expect(StorageChangeFlow.needsPreview(budget: .mib500, from: .unlimited))
        #expect(!StorageChangeFlow.needsPreview(budget: .unlimited, from: .mib500))
    }

    @Test func aPreviewOfZeroAppliesWithoutAsking() {
        #expect(StorageChangeFlow.after(previewCount: 0) == .applyNow)
        #expect(StorageChangeFlow.after(previewCount: 12) == .confirm(count: 12))
    }

    @Test func everyEnumValueHasALabelInTheCatalogue() {
        let labels: [SettingsString] =
            RetentionPreset.allCases.map(\.label) + ImageBudget.allCases.map(\.label)
            + ImageQuality.allCases.flatMap { [$0.label, $0.caption] } + CaptureMode.allCases.flatMap { [$0.label, $0.caption] }
            + ShelfPlacement.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { FlotsamStrings.text(forKey: $0.key) != nil })
    }
}

@Suite struct SettingsStringTests {
    @Test func theEnumAndTheCatalogueHoldTheSameKeys() throws {
        let catalogue = try Repo.catalogue()
        let inCatalogue = Set(catalogue.keys.filter { $0.hasPrefix("ui.settings.") })
        let inCode = Set(SettingsString.allCases.map(\.key))
        #expect(inCode.subtracting(inCatalogue).isEmpty, "keys with no catalogue entry")
        #expect(inCatalogue.subtracting(inCode).isEmpty, "catalogue entries no view can use")
    }

    @Test func everyStringIsWithinTheLengthBudget() throws {
        let catalogue = try Repo.catalogue()
        for string in SettingsString.allCases {
            let value = try #require(catalogue[string.key])
            #expect(value.count <= 140, "\(string.key) is \(value.count) characters")
        }
    }

    @Test func shortenConfirmationNamesTheCountAndThePeriod() {
        let text = SettingsString.confirmShorten.text(count: 37, label: .retention7Days)
        #expect(text.contains("37") && text.contains("7 days"))
        #expect(!text.contains("%"))
    }

    @Test func budgetConfirmationNamesTheCountAndTheSize() {
        let text = SettingsString.confirmBudget.text([.count(4), .byteSize(3 * 1024 * 1024)])
        #expect(text.contains("4") && text.contains("3 MB"))
        #expect(!text.contains("%"))
    }

    @Test func mismatchedArgumentsLeaveTheTemplateInsteadOfCrashing() {
        let template = SettingsString.confirmBudget.text
        #expect(SettingsString.confirmBudget.text([.byteSize(1), .count(1)]) == template)
        #expect(SettingsString.confirmShorten.text([.count(1)]) == SettingsString.confirmShorten.text)
    }

    @Test func aboutVersionLineFillsVersionAndBuild() {
        let text = SettingsString.version.text(version: "0.1.0", build: "1")
        #expect(text == "Version 0.1.0 (1)")
        #expect(SettingsString.launchAtLogin.text(version: "0.1.0", build: "1") == SettingsString.launchAtLogin.text)
    }
}
