import AppKit
import FlotsamBase
import SwiftUI

/// About (FR-008-09): version, licence, diagnostics copy, data folder and the project page. The Project Page button
/// opens the browser only when the user clicks it; nothing here makes a request.
struct AboutPane: View {
    let model: SettingsModel
    @State private var showingLicence = false
    @State private var copying = false

    var body: some View {
        let environment = DiagnosticsEnvironment.current
        Form {
            Section {
                Text(.tagline)
                Text(verbatim: SettingsString.version.text(version: environment.appVersion, build: environment.build))
                Text(.licenceLine).settingsCaption()
                Button { showingLicence = true } label: { Text(.viewLicence) }
            }
            Section {
                Button { copy() } label: { Text(.copyDiagnostics) }.disabled(copying)
                Button { model.env.revealDataFolder() } label: { Text(.revealDataFolder) }
                Button { openProjectPage() } label: { Text(.projectPage) }
            }
        }
        .settingsPaneChrome()
        .sheet(isPresented: $showingLicence) { LicenceSheet { showingLicence = false } }
    }

    private func copy() {
        copying = true
        Task {
            switch await model.env.copyDiagnostics() {
            case .success: model.env.hud(SettingsString.diagnosticsCopied.text)
            case .failure(let error): model.env.report(error)
            }
            copying = false
        }
    }

    private func openProjectPage() { NSWorkspace.shared.open(SettingsEnvironment.projectPageURL) }
}

/// The bundled LICENSE file, shown as read-only text. A missing file shows nothing rather than an error: the licence
/// line above already names it, and the file ships in the bundle (project.yml).
private struct LicenceSheet: View {
    let onClose: () -> Void
    private let text: String = {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }()

    var body: some View {
        VStack(alignment: .trailing) {
            ScrollView { Text(verbatim: text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            Button { onClose() } label: { Text(.done) }.keyboardShortcut(.defaultAction)
        }
        .padding()
        .frame(width: 480, height: 360)
        .accessibilityLabel(SettingsString.licenceTitle.text)
    }
}
