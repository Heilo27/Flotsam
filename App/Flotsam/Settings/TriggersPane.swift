import FlotsamBase
import SwiftUI

/// The permission rows (FR-008-13). The owning pane re-reads `rows` through `refreshWhileVisible` (once for the whole
/// group), so a grant made in System Settings shows without reopening the window.
struct PermissionRows: View {
    let probe: any PermissionProbe
    let rows: [PermissionRow]

    var body: some View {
        ForEach(rows) { row in
            LabeledContent {
                HStack {
                    Text(row.status)
                    Button { probe.openSystemSettings(row.kind) } label: { Text(.openSystemSettings) }
                }
            } label: {
                VStack(alignment: .leading) {
                    Text(row.name)
                    Text(row.enables).settingsCaption()
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// Triggers (FR-008-06): the on/off switch, permission state, an inline message while a permission is missing, and the
/// excluded apps.
struct TriggersPane: View {
    let model: SettingsModel
    @State private var rows: [PermissionRow]

    init(model: SettingsModel) {
        self.model = model
        _rows = State(initialValue: PermissionRow.current(probe: model.env.permissions))
    }

    var body: some View {
        let enabled = model.value(SettingKeys.triggersEnabled)
        Form {
            Section {
                Toggle(isOn: model.binding(SettingKeys.triggersEnabled)) { Text(.expandTriggers) }
                PermissionRows(probe: model.env.permissions, rows: rows)
                ForEach(
                    TriggerPermissionNotice.missing(triggersEnabled: enabled, probe: model.env.permissions), id: \.rawValue
                ) { code in
                    Text(verbatim: TriggerPermissionNotice.text(for: code))
                        .settingsCaption()
                }
            }
            Section {
                Text(.excludedAppsHelp).settingsCaption()
                AppListEditor(model: model, key: SettingKeys.triggersExcludedApps, confirmsReset: false)
            } header: {
                Text(.excludedApps)
            }
        }
        .settingsPaneChrome()
        .refreshWhileVisible { rows = PermissionRow.current(probe: model.env.permissions) }
    }
}
