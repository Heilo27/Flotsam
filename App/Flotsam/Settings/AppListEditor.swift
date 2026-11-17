import AppKit
import FlotsamBase
import SwiftUI
import UniformTypeIdentifiers

/// The list editor shared by the ignored-apps list (FR-008-11) and the trigger-excluded list (FR-008-06): each row shows
/// the app's icon and name when installed, otherwise the bundle identifier. The defaults come from the registry key.
struct AppListEditor: View {
    let model: SettingsModel
    let key: SettingKey<BundleIdentifierList>
    /// Ignored apps ask before replacing the list (FR-008-11); the trigger list resets directly.
    let confirmsReset: Bool
    @State private var confirmingReset = false

    var body: some View {
        ForEach(model.value(key).identifiers, id: \.self) { identifier in
            AppRow(identifier: identifier) { remove(identifier) }
        }
        HStack {
            Button { add() } label: { Text(.addApp) }
            Spacer()
            Button { confirmsReset ? (confirmingReset = true) : reset() } label: { Text(.resetToDefaults) }
        }
        .alert(SettingsString.confirmResetIgnoredTitle.text, isPresented: $confirmingReset) {
            Button(SettingsString.resetAction.text, role: .destructive) { reset() }
            Button(SettingsString.cancel.text, role: .cancel) {}
        } message: {
            Text(.confirmResetIgnored)
        }
    }

    private func remove(_ identifier: String) {
        model.env.settings.set(model.env.settings.value(key).removing(identifier), for: key)
    }

    private func reset() { model.env.settings.set(key.defaultValue, for: key) }

    /// "Add…" opens an application picker starting in /Applications and reads the chosen bundle's identifier; a
    /// bundle without one is `SET-VAL-002` (FR-008-11). A duplicate is ignored silently by `adding`.
    private func add() {
        let panel = NSOpenPanel()
        panel.title = SettingsString.chooseApp.text
        panel.prompt = SettingsString.chooseAppPrompt.text
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch BundleIdentifierList.validated(Bundle(url: url)?.bundleIdentifier) {
        case .success(let identifier):
            model.env.settings.set(model.env.settings.value(key).adding(identifier), for: key)
        case .failure(let error):
            model.env.report(error)
        }
    }
}

private struct AppRow: View {
    let identifier: String
    let onRemove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        let name = url.map { FileManager.default.displayName(atPath: $0.path) }
        let removeLabel = "\(SettingsString.removeApp.text) \(name ?? identifier)"
        HStack {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading) {
                Text(verbatim: name ?? identifier)
                if name == nil { Text(.notInstalled).settingsCaption() }
            }
            Spacer()
            Button { onRemove() } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel(removeLabel)
        }
        .accessibilityElement(children: .contain)
    }
}
