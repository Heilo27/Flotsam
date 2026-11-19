import Foundation
import Testing
@testable import FlotsamBase

/// TASK-498, FR-008-11 / AC-008-06: the ignored-apps default went from six password managers to empty. These pin the
/// one-time migration for installs that still carry the old six on disk. Expected lists are literals, not the
/// production constant, so a change to the constant cannot move the oracle with it.
@Suite struct IgnoredAppsMigrationTests {
    private static let oldSix = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]
    private static let key = "privacy.ignoredApps"

    private func store(holding list: [String]?) -> MemoryKeyValueStore {
        let store = MemoryKeyValueStore()
        if let list { store.setString(BundleIdentifierList(list).persisted, forKey: Self.key) }
        return store
    }

    private func stored(_ store: MemoryKeyValueStore) -> [String]? {
        store.string(forKey: Self.key).flatMap(BundleIdentifierList.init(persisted:))?.identifiers
    }

    @Test func theNewDefaultIsEmpty() {
        #expect(SettingsStore(store: MemoryKeyValueStore()).value(SettingKeys.privacyIgnoredApps).identifiers.isEmpty)
    }

    @Test func exactOldDefaultIsCleared() {
        let store = store(holding: Self.oldSix)
        #expect(IgnoredAppsMigration.run(on: store))
        #expect(stored(store) == [])
        #expect(SettingsStore(store: store).value(SettingKeys.privacyIgnoredApps).identifiers.isEmpty)
    }

    @Test func oldDefaultInAnotherOrderIsStillTheDefault() {
        let store = store(holding: Self.oldSix.reversed())
        #expect(IgnoredAppsMigration.run(on: store))
        #expect(stored(store) == [])
    }

    @Test func aCustomisedListIsKept() {
        let cases: [[String]] = [
            Self.oldSix + ["com.apple.TextEdit"],  // added one
            Array(Self.oldSix.dropLast()),  // removed one
            ["com.1password.1password"],  // kept only one
            ["com.example.other"],  // unrelated
        ]
        for list in cases {
            let store = store(holding: list)
            #expect(!IgnoredAppsMigration.run(on: store), "\(list.count) entries")
            #expect(stored(store) == list)
        }
    }

    @Test func anEmptyStoredListStaysEmpty() {
        let store = store(holding: [])
        #expect(!IgnoredAppsMigration.run(on: store))
        #expect(stored(store) == [])
    }

    @Test func nothingStoredIsLeftAlone() {
        let store = store(holding: nil)
        #expect(!IgnoredAppsMigration.run(on: store))
        #expect(store.string(forKey: Self.key) == nil, "the new default applies without writing anything")
    }

    @Test func anUnreadableStoredValueIsNotTouched() {
        let store = MemoryKeyValueStore()
        store.setString("not json", forKey: Self.key)
        #expect(!IgnoredAppsMigration.run(on: store))
        #expect(store.string(forKey: Self.key) == "not json", "SettingsStore replaces it on first read, FR-008-02")
    }

    @Test func aListWithTheOldSixAndADuplicateIsNotTheDefault() {
        let store = store(holding: Self.oldSix + [Self.oldSix[0]])
        #expect(!IgnoredAppsMigration.run(on: store))
        #expect(stored(store)?.count == 7)
    }

    @Test func itRunsOnceSoALaterDeliberateListSurvivesEveryLaunch() {
        let store = store(holding: Self.oldSix)
        #expect(IgnoredAppsMigration.run(on: store))
        // the user, on purpose, lists all six again
        store.setString(BundleIdentifierList(Self.oldSix).persisted, forKey: Self.key)
        #expect(!IgnoredAppsMigration.run(on: store))
        #expect(Set(stored(store) ?? []) == Set(Self.oldSix))
    }

    @Test func aFreshInstallIsMarkedSoItIsNeverMigratedLater() {
        let store = store(holding: nil)
        _ = IgnoredAppsMigration.run(on: store)
        store.setString(BundleIdentifierList(Self.oldSix).persisted, forKey: Self.key)
        #expect(!IgnoredAppsMigration.run(on: store))
        #expect(stored(store)?.count == 6)
    }
}
