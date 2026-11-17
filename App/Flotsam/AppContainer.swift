import AppKit
import FlotsamBase
import FlotsamLibrary
import FlotsamPaste
import FlotsamStorage
import Foundation
import Observation

/// Composition root: builds the long-lived objects once at launch. Failure here is the Fatal path
/// (STO-IO-002 / STO-DB-003): the error goes to `ErrorReporter`, which logs it and asks the presenter for the
/// Fatal alert (FR-000-04).
@MainActor
@Observable
final class AppContainer {
    private(set) var database: FlotsamDatabase?
    let presenter: ErrorPresenterAdapter
    let reporter: ErrorReporter
    /// The Library panel (FR-003-01). Nil until the database has opened; the menu item is disabled until then.
    private(set) var library: LibraryPanelController?
    private var libraryHotkey: LibraryHotkey?

    init() {
        let presenter = ErrorPresenterAdapter(dataFolder: Self.dataFolder)
        self.presenter = presenter
        reporter = ErrorReporter(presenter: presenter)
        Task { await openDatabase() }
    }

    /// The data folder, also what the Fatal alert reveals. One definition so "reveal" always opens the folder the
    /// database was attempted in.
    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flotsam", isDirectory: true)
    }

    private func openDatabase() async {
        switch await FlotsamDatabase.open(folder: Self.dataFolder) {
        case .success(let opened):
            database = opened
            startLibrary(database: opened)
        case .failure(let error): await reporter.report(error, origin: .background)
        }
    }

    /// Builds the Library stack over the opened database and registers its hotkey (FR-003-01, FR-005-01).
    private func startLibrary(database: FlotsamDatabase) {
        let reporter = reporter
        let settings = SettingsStore(store: UserDefaultsStore()) { keyName in
            let error = FlotsamError(.setDat001, "setting \(keyName) was invalid; its default is in use")
            Task { await reporter.report(error, origin: .background) }
        }
        let preferences = SettingsLibraryPreferences(settings: settings)
        let probe = AccessibilityPermissionProbe()
        let frontmost = WorkspaceFrontmostAppProvider()
        let paster = PasteService(
            store: database, pasteboard: NSPasteboardAdapter(), files: LocalFileSystem(), frontmost: frontmost,
            accessibility: probe, keys: CGEventKeyPoster(), clock: SystemClock(), ownWrites: OwnWriteLedger())

        // Set once the controller exists: the model needs its host (the controller) and the controller needs the model.
        let effects = LibraryEffects(
            report: { error in Task { await reporter.report(error, origin: .userInitiated) } },
            reveal: { paths in
                NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            },
            // Settings (FRD-008) and the organise/trigger commands (FRD-004, FRD-005) are not built yet: inert until then.
            openSettings: {},
            external: { _, _ in },
            isAccessibilityTrusted: { probe.isAccessibilityTrusted })
        let controller = LibraryPanelController(
            source: database, paster: paster, preferences: preferences, effects: effects, frontmost: frontmost,
            // FRD-001's ClipboardCapture is not merged yet: nothing to flush before the Library opens.
            captureNow: {})
        library = controller

        // Seam: FRD-008's `shortcuts.openLibrary` setting replaces `DefaultLibraryHotkeyPreferences` here when it merges.
        let hotkey = LibraryHotkey(
            registrar: CarbonHotkeyRegistrar(), preferences: DefaultLibraryHotkeyPreferences()
        ) { [weak controller] in controller?.toggle() }
        if case .failure(let error) = hotkey.apply() {
            Task { await reporter.report(error, origin: .background) }
        }
        libraryHotkey = hotkey
    }
}
