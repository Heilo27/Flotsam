import AppKit
import FlotsamBase
import SwiftUI

/// Privacy (FR-008-07): ignored apps, what is never stored, the "Paste from Other Apps" row and the no-network line.
/// Nothing in this pane sends anything anywhere.
struct PrivacyPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                Text(.ignoredAppsHelp).settingsCaption()
                AppListEditor(model: model, key: SettingKeys.privacyIgnoredApps, confirmsReset: true)
                Button { addPasswordManagers() } label: { Text(.addPasswordManagers) }
                    .accessibilityHint(SettingsString.addPasswordManagersHelp.text)
                Text(.addPasswordManagersHelp).settingsCaption()
            } header: {
                Text(.ignoredApps)
            }
            Section {
                Text(.neverStored)
                PasteboardAccessRow()
                Text(.noNetwork)
            }
        }
        .settingsPaneChrome()
    }

    /// One tap adds the known password managers (FR-008-11); the user's own entries stay and a duplicate is skipped.
    private func addPasswordManagers() {
        let key = SettingKeys.privacyIgnoredApps
        let merged = model.env.settings.value(key).adding(contentsOf: BundleIdentifierList.passwordManagerPreset)
        model.env.settings.set(merged, for: key)
    }
}

/// The "Paste from Other Apps" row (FR-008-07, FR-008-13). Reads the system setting through `PasteboardAccess`, the same
/// probe onboarding uses; reading it never triggers the system alert. Re-read on appear, on app activation and every 2 s
/// while the pane is visible (`refreshWhileVisible`, FR-008-13 rule b), so a change made in System Settings shows on
/// return, or beside it. Status is words, never colour alone (FR-008-17).
private struct PasteboardAccessRow: View {
    @State private var isAllowed = PasteboardAccess.isAllowed

    var body: some View {
        LabeledContent {
            HStack {
                Text(isAllowed ? .permissionGranted : .permissionNotGranted)
                Button { PasteboardAccess.openSystemSettings() } label: { Text(.openSystemSettings) }
            }
        } label: {
            VStack(alignment: .leading) {
                Text(.pasteOtherApps)
                Text(.pasteOtherAppsHelp).settingsCaption()
            }
        }
        .accessibilityElement(children: .contain)
        .refreshWhileVisible { isAllowed = PasteboardAccess.isAllowed }
    }
}
