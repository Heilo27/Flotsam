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

    /// FR-000-09. given one code per module (a different one from OC-0031's), then each logs under its own module's
    /// category. A code mapped to a neighbouring module's category turns this red.
    @Test func everyModuleHasALogCategory() {
        #expect(ErrorCode.capIo001.logCategory.rawValue == "capture")
        #expect(ErrorCode.sspLim001.logCategory.rawValue == "screenshots")
        #expect(ErrorCode.libIo001.logCategory.rawValue == "library")
        #expect(ErrorCode.orgLim001.logCategory.rawValue == "organize")
        #expect(ErrorCode.trgOs002.logCategory.rawValue == "triggers")
        #expect(ErrorCode.shfLim001.logCategory.rawValue == "shelf")
        #expect(ErrorCode.stoIo002.logCategory.rawValue == "storage")
        #expect(ErrorCode.setVal001.logCategory.rawValue == "settings")
    }
}
