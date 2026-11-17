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
            } header: {
                Text(.ignoredApps)
            }
            Section {
                Text(.neverStored)
                // The "Paste from Other Apps" state has no probe yet (FRD-001 FR-001-18 owns reading it), so the
                // state is shown as unknown. TODO(FRD-001): read the real state here and show Granted / Not granted.
                LabeledContent {
                    Text(.permissionUnknown)
                } label: {
                    VStack(alignment: .leading) {
                        Text(.pasteOtherApps)
                        Text(.pasteOtherAppsHelp).settingsCaption()
                    }
                }
                Text(.noNetwork)
            }
        }
        .settingsPaneChrome()
    }
}
