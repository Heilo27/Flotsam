import FlotsamBase
import FlotsamStorage
import Foundation
import Observation
import AppKit

/// Composition root: builds the long-lived objects once at launch. Failure here is the Fatal path
/// (STO-IO-002 / STO-DB-003): the error goes to `ErrorReporter`, which logs it and asks the presenter for the
/// Fatal alert (FR-000-04).
@MainActor
@Observable
final class AppContainer {
    private(set) var database: FlotsamDatabase?
    let presenter: ErrorPresenterAdapter
    let reporter: ErrorReporter
    /// The Settings window (FR-008-03). Every "Open Settings" caller goes through `settings.openSettings()`.
    private(set) var settings: SettingsWindowController!

    init() {
        let presenter = ErrorPresenterAdapter(dataFolder: Self.dataFolder)
        self.presenter = presenter
        let reporter = ErrorReporter(presenter: presenter)
        self.reporter = reporter
        settings = SettingsWindowController(env: makeSettingsEnvironment(presenter: presenter, reporter: reporter))
        Task { await openDatabase() }
    }

    /// The seams the Settings window takes from the rest of the app. Each default here is a local stand-in a later
    /// FRD can replace without touching the window: the settings store (UserDefaults-backed), the login item and
    /// permission adapters (App/Platform), the database provider, the setup guide and the diagnostics copy.
    private func makeSettingsEnvironment(presenter: ErrorPresenterAdapter, reporter: ErrorReporter) -> SettingsEnvironment {
        let store = SettingsStore(store: UserDefaultsStore()) { keyName in
            // SET-DAT-001 once per launch per key: a stored value was unreadable and the default was substituted.
            Task { await reporter.report(FlotsamError(.setDat001, "Setting \(keyName) was invalid and reset"), origin: .background) }
        }
        let probe = SystemPermissionProbe()
        let storage = SettingsStorage(database: { [weak self] in self?.database })
        let loginService = SystemLoginItemService()
        return SettingsEnvironment(
            settings: store,
            login: LoginItemController(service: loginService),
            openLoginItems: { loginService.openLoginItemsSettings() },
            permissions: probe,
            storage: storage,
            dataFolder: Self.dataFolder,
            revealDataFolder: { NSWorkspace.shared.open(Self.dataFolder) },
            report: { error in Task { await reporter.report(error, origin: .userInitiated) } },
            hud: { message in presenter.showHUD(message: message) },
            // TODO(FRD-008 FR-008-12): reopen onboarding here once the onboarding window exists.
            showSetupGuide: {},
            copyDiagnostics: {
                await SettingsDiagnostics.copy(settings: store, probe: probe, storage: storage, reporter: reporter)
            })
    }

    /// The data folder, also what the Fatal alert reveals. One definition so "reveal" always opens the folder the
    /// database was attempted in.
    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flotsam", isDirectory: true)
    }

    private func openDatabase() async {
        switch await FlotsamDatabase.open(folder: Self.dataFolder) {
        case .success(let opened): database = opened
        case .failure(let error): await reporter.report(error, origin: .background)
        }
    }
}
