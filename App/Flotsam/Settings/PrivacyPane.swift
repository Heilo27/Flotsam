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
}

/// The "Paste from Other Apps" row (FR-008-07, FR-008-13). Reads the system setting through `PasteboardAccess`, the same
/// probe onboarding uses; reading it never triggers the system alert. Re-read when the pane appears and whenever the app
/// becomes active, so a change made in System Settings shows on return. Status is words, never colour alone (FR-008-17).
private struct PasteboardAccessRow: View {
    @State private var isAllowed = PasteboardAccess.isAllowed

    var body: some View {
        LabeledContent {
            HStack {
                Text(isAllowed ? .permissionGranted : .permissionNotGranted)
                if PasteboardAccess.isGated {
                    Button { PasteboardAccess.openSystemSettings() } label: { Text(.openSystemSettings) }
                }
            }
        } label: {
            VStack(alignment: .leading) {
                Text(.pasteOtherApps)
                Text(.pasteOtherAppsHelp).settingsCaption()
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { isAllowed = PasteboardAccess.isAllowed }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isAllowed = PasteboardAccess.isAllowed
        }
    }
}
