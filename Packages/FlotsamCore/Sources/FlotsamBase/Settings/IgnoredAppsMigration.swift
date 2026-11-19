import Foundation

/// One-time migration for FR-008-11: the ignored-apps default went from six password managers to empty when secure
/// clips began storing concealed copies encrypted. An install that never touched the list may still carry the old six
/// on disk (a stored value is written when the user edits or resets the list, and when an invalid value is replaced).
/// Left alone, 1Password and the others would stay ignored for good and never reach the secure path.
///
/// The rule, in one place:
/// - The stored list holds exactly the retired six (as a set; order carries no meaning): the user never customised it,
///   so it becomes empty.
/// - Any other stored list is the user's choice and is kept, even one that contains some of the six.
/// - No stored list, or one that does not read: nothing to do (the new default applies; an unreadable value is
///   replaced by the default on its first read, FR-008-02).
/// - It runs once. Without the marker a user who later adds all six deliberately would lose them at every launch.
///
/// Reads and writes `privacy.ignoredApps` directly rather than through `SettingsStore`: the store's job is validated,
/// typed access and change delivery, and nothing is subscribed this early in launch. The marker is migration
/// bookkeeping, not a setting, so it has no row in `SettingKeys`.
public enum IgnoredAppsMigration {
    static let markerKey = "migration.ignoredAppsEmptyDefault"

    /// Runs the migration against `store` and reports whether it cleared the list. Call once, before the list is read.
    @discardableResult
    public static func run(on store: any KeyValueStore) -> Bool {
        guard store.string(forKey: markerKey) == nil else { return false }
        defer { store.setString("done", forKey: markerKey) }
        let key = SettingKeys.privacyIgnoredApps.name
        guard let stored = store.string(forKey: key), let list = BundleIdentifierList(persisted: stored),
            Set(list.identifiers) == Set(BundleIdentifierList.retiredIgnoredAppsDefault.identifiers),
            list.identifiers.count == BundleIdentifierList.retiredIgnoredAppsDefault.identifiers.count
        else { return false }
        store.setString(BundleIdentifierList.defaultIgnoredApps.persisted, forKey: key)
        return true
    }
}
