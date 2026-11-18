import Foundation
import Testing
@testable import FlotsamBase

/// FRD-005 8T slice S9: the trigger excluded-apps default list on a fresh install (OC-5094). Expected values are literals.
@Suite struct FRD005ContractTestsLifecycleDefaults {
    // Red if a default app is dropped, renamed or added, if the order of the list changes, or if Flotsam's own bundle
    // appears in the list.
    @Test("OC-5094 a fresh install's excluded-apps list holds exactly the 11 defaults and Flotsam is not among them")
    func oc5094_freshInstallExcludedApps() {
        // given: a fresh preferences domain nobody has written to
        let name = "flotsam.frd005.s9.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let settings = SettingsStore(store: UserDefaultsStore(defaults: UserDefaults(suiteName: name)!), onInvalid: { _ in })
        // when: Settings > Triggers reads the list
        let list = settings.value(SettingKeys.triggersExcludedApps).identifiers
        // then: the eleven defaults (Terminal, iTerm2, kitty, Ghostty, Alacritty, Warp, Hyper, Microsoft Remote Desktop,
        // Screen Sharing, Parallels Desktop, VMware Fusion) and nothing else
        #expect(list == [
            "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "io.alacritty",
            "dev.warp.Warp-Stable", "co.zeit.hyper", "com.microsoft.rdc.macos", "com.apple.ScreenSharing",
            "com.parallels.desktop.console", "com.vmware.fusion",
        ])
        #expect(list.count == 11)
        #expect(!list.contains { $0.localizedCaseInsensitiveContains("flotsam") })
    }

    // Red if reading the default writes it to disk (a later change of the shipped default would then never reach users),
    // or if a relaunch changes the list.
    @Test("OC-5094 boundary: reading the default writes nothing, and a relaunch (fresh SettingsStore) reads the same eleven")
    func oc5094_defaultIsNotPersisted() {
        // given: a fresh domain, read once
        let name = "flotsam.frd005.s9.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        _ = SettingsStore(store: UserDefaultsStore(defaults: defaults), onInvalid: { _ in }).value(SettingKeys.triggersExcludedApps)
        // when: the app relaunches
        let relaunched = SettingsStore(store: UserDefaultsStore(defaults: UserDefaults(suiteName: name)!), onInvalid: { _ in })
        // then: the key is still absent on disk and the list is the same eleven
        #expect(defaults.string(forKey: "triggers.excludedApps") == nil)
        #expect(relaunched.value(SettingKeys.triggersExcludedApps).identifiers.count == 11)
    }
}
