import FlotsamBase
import SwiftUI

/// The permission rows (FR-008-13), refreshed while the pane is on screen so a grant made in System Settings shows
/// without reopening the window. Shared by Triggers and Privacy.
struct PermissionRows: View {
    let probe: any PermissionProbe
    @State private var rows: [PermissionRow]

    init(probe: any PermissionProbe) {
        self.probe = probe
        _rows = State(initialValue: PermissionRow.current(probe: probe))
    }

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
        .task {
            while !Task.isCancelled {
                rows = PermissionRow.current(probe: probe)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// Triggers (FR-008-06): the on/off switch, permission state, an inline message while a permission is missing, and the
/// excluded apps.
struct TriggersPane: View {
    let model: SettingsModel

    var body: some View {
        let enabled = model.value(SettingKeys.triggersEnabled)
        Form {
            Section {
                Toggle(isOn: model.binding(SettingKeys.triggersEnabled)) { Text(.expandTriggers) }
                PermissionRows(probe: model.env.permissions)
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
    }
}
