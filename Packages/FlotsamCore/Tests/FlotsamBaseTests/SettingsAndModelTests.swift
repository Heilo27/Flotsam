import Foundation
import Testing
@testable import FlotsamBase

private final class MemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

@Suite struct SettingsTests {
    @Test func defaultsMatchFRD008Registry() {
        let settings = SettingsStore(store: MemoryStore())
        #expect(settings.value(SettingKeys.captureMode) == .active)
        #expect(settings.value(SettingKeys.storageRetention) == .d30)
        #expect(settings.value(SettingKeys.storageImageBudget) == .gib2)
        #expect(settings.value(SettingKeys.storageImageQuality) == .original)
    }

    @Test func roundTripsAValue() {
        let settings = SettingsStore(store: MemoryStore())
        settings.set(.curated, for: SettingKeys.captureMode)
        #expect(settings.value(SettingKeys.captureMode) == .curated)
    }

    @Test func unknownStoredValueRecoversToDefaultAndSaysSo() {
        let store = MemoryStore()
        store.setString("fortnight", forKey: SettingKeys.storageRetention.name)
        let reading = SettingsStore(store: store).read(SettingKeys.storageRetention)
        #expect(reading.value == .d30)
        #expect(reading.recoveredFromInvalid)
    }
}

@Suite struct SearchNormalizerTests {
    @Test func foldsCaseAndDiacritics() {
        #expect(SearchNormalizer.normalize("Café RÉSUMÉ") == "cafe resume")
    }

    @Test func splitsOnWhitespaceAndKeepsShortTokens() {
        #expect(SearchNormalizer.tokens(from: "  Ab\tc  ÉD ") == ["ab", "c", "ed"])
        #expect(SearchNormalizer.tokens(from: "   ").isEmpty)
    }
}

@Suite struct LogSafetyTests {
    @Test func contextValuesRenderWithoutFreeText() {
        #expect(LogSafeValue.bytes(12).rendered == "12B")
        #expect(LogSafeValue.milliseconds(40).rendered == "40ms")
    }

    @Test func everyModuleHasALogCategory() {
        #expect(LogCategory.allCases.count == 9)
    }
}
