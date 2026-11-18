import Foundation
import Testing
@testable import FlotsamBase

/// Collects the keys `onInvalid` reports: each one is a SET-DAT-001 in the app (FR-008-02).
private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func record(_ name: String) { lock.withLock { names.append(name) } }
    var all: [String] { lock.withLock { names } }
}

/// TASK-454: onboarding showed a SET-DAT-001 notice. Cause: `Bool(persisted:)` accepted only "true"/"false", but
/// `UserDefaults` returns its own boolean spellings as "1"/"0" (`defaults write -bool`, `.set(true)`) and "YES"/"NO"
/// (a `-key NO` launch argument, which is how onboarding is forced). Those were treated as corrupt.
@Suite struct Task454OnboardingNoticeTests {
    /// A real `UserDefaults` domain, so the test sees what the system really hands back, not a fake's strings.
    private func withDomain(_ body: (UserDefaults, SettingsStore, Reported) -> Void) {
        let name = "flotsam.task454.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not create a scratch defaults domain")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        let reported = Reported()
        let settings = SettingsStore(store: UserDefaultsStore(defaults: defaults)) { reported.record($0) }
        body(defaults, settings, reported)
    }

    /// AC "a normal first launch raises no SET-DAT-001": nothing stored, every registry key read, nothing reported.
    @Test func firstLaunchReadsEveryKeyWithoutRaising() {
        let reported = Reported()
        let settings = SettingsStore(store: MemoryKeyValueStore()) { reported.record($0) }
        _ = settings.value(SettingKeys.captureMode)
        _ = settings.value(SettingKeys.screenshotsEnabled)
        _ = settings.value(SettingKeys.screenshotsFolderOverride)
        _ = settings.value(SettingKeys.shelfEnabled)
        _ = settings.value(SettingKeys.shelfPlacement)
        _ = settings.value(SettingKeys.shelfRevealOnEdgeHover)
        _ = settings.value(SettingKeys.shortcutsOpenLibrary)
        _ = settings.value(SettingKeys.shortcutsSaveClipboard)
        _ = settings.value(SettingKeys.shortcutsToggleShelf)
        _ = settings.value(SettingKeys.triggersEnabled)
        _ = settings.value(SettingKeys.triggersExcludedApps)
        _ = settings.value(SettingKeys.privacyIgnoredApps)
        _ = settings.value(SettingKeys.storageRetention)
        _ = settings.value(SettingKeys.storageImageBudget)
        _ = settings.value(SettingKeys.storageImageQuality)
        _ = settings.value(SettingKeys.librarySort)
        _ = settings.value(SettingKeys.libraryViewMode)
        _ = settings.value(SettingKeys.libraryPanelSize)
        _ = settings.value(SettingKeys.onboardingCompleted)
        _ = settings.value(SettingKeys.settingsLastPane)
        #expect(reported.all.isEmpty)
        #expect(OnboardingFlow.shouldShowAutomatically(settings: settings))
    }

    /// The path onboarding takes on exit: it writes `onboarding.completed`, and the next launch reads it back through
    /// a real `UserDefaults`. Nothing is raised.
    @Test func completedFlagRoundTripsThroughRealDefaults() {
        withDomain { _, settings, reported in
            settings.set(true, for: SettingKeys.onboardingCompleted)
            #expect(settings.value(SettingKeys.onboardingCompleted) == true)
            #expect(OnboardingFlow.shouldShowAutomatically(settings: settings) == false)
            #expect(reported.all.isEmpty)
        }
    }

    /// The cause. A boolean stored natively (what `defaults write -bool` and `UserDefaults.set(_:forKey:)` produce)
    /// reads back as a string "1"/"0". It is a valid boolean: no notice, and the value is honoured.
    @Test func nativeBooleanInDefaultsIsNotCorrupt() {
        withDomain { defaults, settings, reported in
            defaults.set(false, forKey: "onboarding.completed")
            defaults.set(false, forKey: "shelf.enabled")
            defaults.set(true, forKey: "shelf.revealOnEdgeHover")
            #expect(settings.value(SettingKeys.onboardingCompleted) == false)
            #expect(settings.value(SettingKeys.shelfEnabled) == false)
            #expect(settings.value(SettingKeys.shelfRevealOnEdgeHover) == true)
            #expect(reported.all.isEmpty)
        }
    }

    /// The forcing path: `-onboarding.completed NO` lands in the argument domain as the string "NO".
    @Test(arguments: [("NO", false), ("YES", true), ("0", false), ("1", true), ("false", false), ("true", true)])
    func cocoaSpellingsOfBooleanReadAsThatBoolean(text: String, expected: Bool) {
        let raw = MemoryKeyValueStore()
        raw.setString(text, forKey: "onboarding.completed")
        let reported = Reported()
        let settings = SettingsStore(store: raw) { reported.record($0) }
        let reading = settings.read(SettingKeys.onboardingCompleted)
        #expect(reading.value == expected)
        #expect(reading.recoveredFromInvalid == false)
        #expect(reported.all.isEmpty)
        #expect(raw.string(forKey: "onboarding.completed") == text, "a valid value is not rewritten")
    }

    /// The fix must not widen validity: text that is not a boolean still resets and raises once.
    @Test(arguments: ["maybe", "2", "", "-1", "yes", "no", "True", "FALSE", "TRUE ", "nil"])
    func nonBooleanTextIsStillInvalid(text: String) {
        let raw = MemoryKeyValueStore()
        raw.setString(text, forKey: "shelf.enabled")
        let reported = Reported()
        let settings = SettingsStore(store: raw) { reported.record($0) }
        #expect(settings.value(SettingKeys.shelfEnabled) == true)
        #expect(reported.all == ["shelf.enabled"])
        #expect(raw.string(forKey: "shelf.enabled") == "true")
    }

    /// What the app writes is unchanged: "true"/"false".
    @Test func writtenFormIsUnchanged() {
        #expect(true.persisted == "true")
        #expect(false.persisted == "false")
    }
}
