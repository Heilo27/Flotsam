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
            LocalAIAccessSection(model: model)
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

/// Local AI access (FRD-010, FR-010-02, FR-010-05, FR-010-11): the off-by-default switch, the helper path to give an AI
/// app, and the approved apps with a Revoke each. Turning the switch on asks first (the cloud warning); turning it off
/// needs no question. Approved apps and the path show only while the switch is on.
private struct LocalAIAccessSection: View {
    let model: SettingsModel

    var body: some View {
        let key = SettingKeys.mcpEnabled
        let isOn = Binding(
            get: { model.value(key) },
            set: { wanted in
                // Cancel leaves the setting as it was: the toggle reads the stored value again and stays off.
                guard !wanted || model.env.confirmEnableMCP() else { return }
                model.env.settings.set(wanted, for: key)
            })
        Section {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading) {
                    Text(.mcpToggle)
                    Text(.mcpHelp).settingsCaption()
                }
            }
            if model.value(key) {
                LabeledContent {
                    Text(verbatim: model.env.mcpHelperPath).textSelection(.enabled).settingsCaption()
                } label: {
                    Text(.mcpHelperPath)
                }
                approvedClients
            }
        } header: {
            Text(.mcpHeader)
        }
    }

    @ViewBuilder
    private var approvedClients: some View {
        let approvals = model.value(SettingKeys.mcpApprovals).approvals
        if approvals.isEmpty {
            Text(.mcpNoClients).settingsCaption()
        }
        ForEach(approvals, id: \.key) { approval in
            LabeledContent {
                Button { revoke(approval) } label: { Text(.mcpRevoke) }
                    .accessibilityHint(SettingsString.mcpRevokeHelp.text)
            } label: {
                VStack(alignment: .leading) {
                    Text(verbatim: approval.name)
                    Text(verbatim: approval.detail).settingsCaption()
                }
            }
        }
    }

    /// FR-010-05: removes the approval; the server closes that client's open connections at once.
    private func revoke(_ approval: MCPApproval) {
        let key = SettingKeys.mcpApprovals
        model.env.settings.set(model.env.settings.value(key).removing(key: approval.key), for: key)
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
