import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShortcuts

/// FR-005-01, FR-005-03, FR-005-04, FR-005-05 registry behaviour, driven through the registrar port.
@MainActor @Suite struct ShortcutRegistryTests {
    private func make(refusing: Set<Chord> = [], system: Set<Chord> = []) -> (ShortcutRegistry, FakeRegistrar) {
        let registrar = FakeRegistrar()
        registrar.refused = refusing
        return (ShortcutRegistry(registrar: registrar, systemHotkeys: FakeSystemHotkeys(chords: system)), registrar)
    }

    @Test func bindRegistersAndPressRunsTheAction() {
        let (registry, registrar) = make()
        var ran = 0
        registry.setAction(.saveClipboard) { ran += 1 }
        #expect(registry.bind(.saveClipboard, to: .cmdK).isSuccess)
        #expect(registry.status(of: .saveClipboard) == .registered)
        registrar.press(.cmdK)
        #expect(ran == 1)
    }

    @Test func rejectedChordChangesNothing() {
        let (registry, registrar) = make()
        _ = registry.bind(.saveClipboard, to: .cmdK)
        let result = registry.bind(.saveClipboard, to: Chord(keyCode: 12, modifiers: .command))
        #expect(result.errorCode == .trgVal003)
        #expect(registry.chord(for: .saveClipboard) == .cmdK)
        #expect(registrar.liveChords == [.cmdK])
    }

    @Test func duplicateAcrossBindingsIsRejectedButOwnChordIsNot() {
        let (registry, _) = make()
        let item = UUID()
        _ = registry.bind(.saveClipboard, to: .cmdK)
        #expect(registry.bind(.item(item), to: .cmdK).errorCode == .trgVal004)
        #expect(registry.bind(.saveClipboard, to: .cmdK).isSuccess)
        #expect(registry.validate(.cmdK, for: .saveClipboard).isSuccess)
    }

    @Test func systemChordIsRejected() {
        let (registry, _) = make(system: [.cmdJ])
        #expect(registry.bind(.toggleShelf, to: .cmdJ).errorCode == .trgVal003)
    }

    @Test func openLibraryCannotBeCleared() {
        let (registry, registrar) = make()
        _ = registry.bind(.openLibrary, to: .ctrlCmdV)
        #expect(registry.bind(.openLibrary, to: nil).errorCode == .trgVal003)
        #expect(registrar.liveChords == [.ctrlCmdV])
    }

    @Test func clearingUnregisters() {
        let (registry, registrar) = make()
        _ = registry.bind(.toggleShelf, to: .cmdK)
        #expect(registry.bind(.toggleShelf, to: nil).isSuccess)
        #expect(registry.status(of: .toggleShelf) == .unbound)
        #expect(registrar.liveChords.isEmpty)
    }

    @Test func refusedRegistrationKeepsTheBindingAndDoesNotBlockOthers() {
        let (registry, registrar) = make(refusing: [.cmdK])
        #expect(registry.bind(.saveClipboard, to: .cmdK).errorCode == .trgOs001)
        #expect(registry.chord(for: .saveClipboard) == .cmdK)
        #expect(registry.status(of: .saveClipboard) == .failed)
        #expect(registry.bind(.toggleShelf, to: .cmdJ).isSuccess)
        #expect(registrar.liveChords == [.cmdJ])
    }

    @Test func retryRegistersAFailedBindingOnceTheOSAllowsIt() {
        let (registry, registrar) = make(refusing: [.cmdK])
        _ = registry.bind(.saveClipboard, to: .cmdK)
        #expect(registry.retryFailed().count == 1)
        registrar.refused = []
        #expect(registry.retryFailed().isEmpty)
        #expect(registry.status(of: .saveClipboard) == .registered)
        #expect(registrar.liveChords == [.cmdK])
    }

    @Test func recordingUnregistersEverythingAndRestoresAfterwards() {
        let (registry, registrar) = make()
        _ = registry.bind(.saveClipboard, to: .cmdK)
        _ = registry.bind(.toggleShelf, to: .cmdJ)
        registry.beginRecording()
        #expect(registrar.liveChords.isEmpty)
        registry.endRecording()
        #expect(registrar.liveChords == [.cmdK, .cmdJ])
        #expect(registry.status(of: .saveClipboard) == .registered)
    }

    @Test func nestedRecordersRestoreOnlyWhenTheLastEnds() {
        let (registry, registrar) = make()
        _ = registry.bind(.saveClipboard, to: .cmdK)
        registry.beginRecording()
        registry.beginRecording()
        registry.endRecording()
        #expect(registrar.liveChords.isEmpty)
        registry.endRecording()
        #expect(registrar.liveChords == [.cmdK])
    }

    @Test func bindingWhileRecordingRegistersAfterwards() {
        let (registry, registrar) = make()
        registry.beginRecording()
        #expect(registry.bind(.saveClipboard, to: .cmdK).isSuccess)
        #expect(registrar.liveChords.isEmpty)
        registry.endRecording()
        #expect(registrar.liveChords == [.cmdK])
    }

    @Test func itemHotkeysSuspendWhileAFlotsamWindowIsKeyButGlobalOnesStay() {
        let (registry, registrar) = make()
        let item = UUID()
        _ = registry.bind(.saveClipboard, to: .cmdK)
        _ = registry.bind(.item(item), to: .cmdJ)
        registry.setItemHotkeysSuspended(true)
        #expect(registrar.liveChords == [.cmdK])
        registry.setItemHotkeysSuspended(false)
        #expect(registrar.liveChords == [.cmdK, .cmdJ])
    }

    @Test func removingAnItemUnregistersItAndFreesTheChord() {
        let (registry, registrar) = make()
        let item = UUID()
        _ = registry.bind(.item(item), to: .cmdJ)
        registry.remove(.item(item))
        #expect(registrar.liveChords.isEmpty)
        #expect(registry.itemBindingCount == 0)
        #expect(registry.bind(.saveClipboard, to: .cmdJ).isSuccess)
    }

    @Test func applyGlobalSettingsBindsTheThreeKeys() {
        let (registry, registrar) = make()
        let settings = SettingsStore(store: InMemoryKeyValueStore())
        settings.set(ChordBinding.chord(.cmdK), for: SettingKeys.shortcutsSaveClipboard)
        #expect(registry.applyGlobalSettings(settings).isEmpty)
        #expect(registrar.liveChords == [.ctrlCmdV, .cmdK])
        settings.set(ChordBinding.none, for: SettingKeys.shortcutsSaveClipboard)
        #expect(registry.applyGlobalSettings(settings).isEmpty)
        #expect(registrar.liveChords == [.ctrlCmdV])
    }

    @Test func unregisterAllLeavesBindingsForRestore() {
        let (registry, registrar) = make()
        _ = registry.bind(.saveClipboard, to: .cmdK)
        registry.unregisterAll()
        #expect(registrar.liveChords.isEmpty)
        #expect(registry.chord(for: .saveClipboard) == .cmdK)
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}

extension Result where Failure == FlotsamError {
    var errorCode: ErrorCode? { if case .failure(let error) = self { error.code } else { nil } }
}
