import Testing
@testable import FlotsamBase

/// TASK-375 (FRD-000 mutation census X003-X008). Key strings are literals from FRD-007 / FRD-008 §registry
/// (FR-007-08, FR-007-09, FR-007-12); the recovery flag is AC-008-02. Expected values never read `SettingKey.name`.
/// Oracle gap: no OC covers the key literals or `recoveredFromInvalid`; tests tagged TASK-375 until one exists.
@Suite struct SettingsKeyLiteralTests {
    /// TASK-375 X003. given a value written under the FRD-007 FR-007-12 key "capture.mode", when read through the
    /// store, then it is that value (not the default); and a write lands under that same literal key.
    /// A key renamed in code (an orphaned user setting) turns both halves red.
    @Test func captureModeIsPersistedUnderItsFRDKey() {
        let raw = MemoryKeyValueStore()
        raw.setString("paused", forKey: "capture.mode")
        #expect(SettingsStore(store: raw).value(SettingKeys.captureMode) == .paused)

        let written = MemoryKeyValueStore()
        SettingsStore(store: written).set(.curated, for: SettingKeys.captureMode)
        #expect(written.string(forKey: "capture.mode") == "curated")
    }

    /// TASK-375 X004. given FR-007-09's key "storage.retention", then reads and writes use exactly that string.
    @Test func retentionIsPersistedUnderItsFRDKey() {
        let raw = MemoryKeyValueStore()
        raw.setString("y1", forKey: "storage.retention")
        #expect(SettingsStore(store: raw).value(SettingKeys.storageRetention) == .y1)

        let written = MemoryKeyValueStore()
        SettingsStore(store: written).set(.d90, for: SettingKeys.storageRetention)
        #expect(written.string(forKey: "storage.retention") == "d90")
    }

    /// TASK-375 X005. given FR-007-08's key "storage.imageBudget", then reads and writes use exactly that string.
    @Test func imageBudgetIsPersistedUnderItsFRDKey() {
        let raw = MemoryKeyValueStore()
        raw.setString("gib10", forKey: "storage.imageBudget")
        #expect(SettingsStore(store: raw).value(SettingKeys.storageImageBudget) == .gib10)

        let written = MemoryKeyValueStore()
        SettingsStore(store: written).set(.mib500, for: SettingKeys.storageImageBudget)
        #expect(written.string(forKey: "storage.imageBudget") == "mib500")
    }

    /// TASK-375 X006. given FR-007-08's key "storage.imageQuality", then reads and writes use exactly that string.
    @Test func imageQualityIsPersistedUnderItsFRDKey() {
        let raw = MemoryKeyValueStore()
        raw.setString("efficient", forKey: "storage.imageQuality")
        #expect(SettingsStore(store: raw).value(SettingKeys.storageImageQuality) == .efficient)

        let written = MemoryKeyValueStore()
        SettingsStore(store: written).set(.balanced, for: SettingKeys.storageImageQuality)
        #expect(written.string(forKey: "storage.imageQuality") == "balanced")
    }

    /// TASK-375 (negative). given a write to one key, then no other registry key is written (one row, one key).
    @Test func writingOneKeyTouchesNoOtherKey() {
        let raw = MemoryKeyValueStore()
        SettingsStore(store: raw).set(.paused, for: SettingKeys.captureMode)
        #expect(raw.string(forKey: "storage.retention") == nil)
        #expect(raw.string(forKey: "storage.imageBudget") == nil)
        #expect(raw.string(forKey: "storage.imageQuality") == nil)
        #expect(raw.string(forKey: "capture.mode") == "paused")
    }
}

@Suite struct SettingsRecoveryFlagTests {
    /// TASK-375 X007. given nothing stored (first launch), when read, then the default is returned and
    /// recoveredFromInvalid is false: absence is not corruption (AC-008-02 raises SET-DAT-001 only on an unknown string).
    @Test func missingValueReturnsDefaultWithoutRecoveryFlag() {
        let reading = SettingsStore(store: MemoryKeyValueStore()).read(SettingKeys.captureMode)
        #expect(reading.value == .active)
        #expect(reading.recoveredFromInvalid == false)
    }

    /// TASK-375 X008. given a valid stored value, when read, then that value is returned and recoveredFromInvalid
    /// is false: a good value must not raise SET-DAT-001.
    @Test func validStoredValueReturnsItWithoutRecoveryFlag() {
        let raw = MemoryKeyValueStore()
        raw.setString("d90", forKey: "storage.retention")
        let reading = SettingsStore(store: raw).read(SettingKeys.storageRetention)
        #expect(reading.value == .d90)
        #expect(reading.recoveredFromInvalid == false)
    }

    /// TASK-375 (the true branch, guards against a mutant that makes the flag constant false).
    /// given an unknown stored string, then the default is returned and recoveredFromInvalid is true.
    @Test func unknownStoredValueSetsRecoveryFlag() {
        let raw = MemoryKeyValueStore()
        raw.setString("fortnight", forKey: "storage.retention")
        let reading = SettingsStore(store: raw).read(SettingKeys.storageRetention)
        #expect(reading.value == .d30)
        #expect(reading.recoveredFromInvalid == true)
    }

    /// TASK-375 (boundary). given an empty string stored, then it is unknown (not absent): default and flag true.
    @Test func emptyStoredStringIsInvalidNotMissing() {
        let raw = MemoryKeyValueStore()
        raw.setString("", forKey: "capture.mode")
        let reading = SettingsStore(store: raw).read(SettingKeys.captureMode)
        #expect(reading.value == .active)
        #expect(reading.recoveredFromInvalid == true)
    }
}
