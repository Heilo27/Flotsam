import AppKit
import FlotsamBase
import FlotsamCapture
import FlotsamLibrary
import FlotsamPaste
import FlotsamStorage
import Foundation

/// Composition root: builds the long-lived objects once at launch. Failure here is the Fatal path
/// (STO-IO-002 / STO-DB-003): the error goes to `ErrorReporter`, which logs it and asks the presenter for the
/// Fatal alert (FR-000-04).
@MainActor
final class AppContainer {
    private(set) var database: FlotsamDatabase?
    let presenter: ErrorPresenterAdapter
    let reporter: ErrorReporter
    /// The typed settings registry over UserDefaults (FR-008-01, -02): the one settings store (ADR-0009). A stored
    /// value that fails validation reads as its default and raises SET-DAT-001 once per launch per key, as a Notice
    /// (no HUD), via `reporter`.
    let settings: SettingsStore
    let permissions: any PermissionProbe
    let loginItem: LoginItemController
    /// What the menu and onboarding can trigger. Each owning FRD fills its own closure; a nil one disables its menu row.
    var actions = AppActions()
    /// Retained for the life of the app; the poll timer only holds it weakly.
    private(set) var capture: ClipboardCapture?
    /// The Library panel (FR-003-01). Nil until the database has opened; the menu item is disabled until then.
    private(set) var library: LibraryPanelController?
    private var libraryHotkey: LibraryHotkey?
    private var unsubscribeHotkey: (@Sendable () -> Void)?
    private var observers: [any NSObjectProtocol] = []
    /// Capture and paste share one ledger so a paste-back is not re-captured as a new copy (FR-001-03).
    private let ownWrites = OwnWriteLedger()

    init() {
        let presenter = ErrorPresenterAdapter(dataFolder: Self.dataFolder)
        let reporter = ErrorReporter(presenter: presenter)
        self.presenter = presenter
        self.reporter = reporter
        settings = SettingsStore(store: .standard) { _ in
            let error = FlotsamError(.setDat001, "A stored setting was invalid and was reset to its default")
            Task { await reporter.report(error, origin: .background) }
        }
        permissions = SystemPermissionProbe()
        loginItem = LoginItemController(service: SMLoginItemService())
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
            startCapture(database: opened)
            startLibrary(database: opened)
        case .failure(let error): await reporter.report(error, origin: .background)
        }
    }

    /// FRD-001: wires capture to the database and starts the poll. Wake and activation each force one immediate
    /// check (FR-001-02 b, c); the launch check runs inside `start()` (FR-001-02 d).
    private func startCapture(database: FlotsamDatabase) {
        let settings = settings
        let capture = ClipboardCapture(
            pasteboard: SystemPasteboard(), sourceApps: SystemSourceApps(), ownWrites: ownWrites,
            ingest: IngestActor(database: database, settings: settings), settings: settings, reporter: reporter,
            // FR-008-11: the list is read per copy, so Settings edits apply without a relaunch.
            ignoredApps: { Set(settings.value(SettingKeys.privacyIgnoredApps).identifiers) })
        self.capture = capture

        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { capture.captureNow() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { capture.captureNow() }
            },
        ]
        capture.start()
    }

    /// Builds the Library stack over the opened database and registers its hotkey (FR-003-01, FR-005-01).
    private func startLibrary(database: FlotsamDatabase) {
        let reporter = reporter
        let probe = permissions
        let frontmost = WorkspaceFrontmostAppProvider()
        let paster = PasteService(
            store: database, pasteboard: SystemPasteboard(), files: LocalFileSystem(), frontmost: frontmost,
            accessibility: probe, keys: CGEventKeyPoster(), clock: SystemClock(), ownWrites: ownWrites)

        let effects = LibraryEffects(
            report: { error in Task { await reporter.report(error, origin: .userInitiated) } },
            reveal: { paths in
                NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            },
            // The organise/trigger commands (FRD-004, FRD-005) are not built yet: inert until then.
            openSettings: { [weak self] in self?.actions.openSettings?() },
            external: { _, _ in },
            isAccessibilityTrusted: { probe.isAccessibilityTrusted })
        let capture = capture
        let controller = LibraryPanelController(
            source: database, paster: paster, preferences: SettingsLibraryPreferences(settings: settings),
            effects: effects, frontmost: frontmost,
            // Flush a copy made in the last poll interval before the Library lists items (FR-003-02).
            captureNow: { capture?.captureNow() })
        library = controller
        actions.openLibrary = { [weak controller] in controller?.toggle() }

        let hotkey = LibraryHotkey(
            registrar: CarbonHotkeyRegistrar(), preferences: SettingsLibraryHotkeyPreferences(settings: settings)
        ) { [weak controller] in controller?.toggle() }
        if case .failure(let error) = hotkey.apply() {
            Task { await reporter.report(error, origin: .background) }
        }
        libraryHotkey = hotkey
        // A rebinding in Settings takes effect at once (FR-005-01).
        let hotkeyName = SettingKeys.shortcutsOpenLibrary.name
        unsubscribeHotkey = settings.subscribe { [weak hotkey] change in
            guard change.name == hotkeyName else { return }
            Task { @MainActor in
                if case .failure(let error) = hotkey?.apply() { await reporter.report(error, origin: .background) }
            }
        }
    }
}

/// Entry points other features own. They are closures, not types, so the app layer depends on none of those features
/// (ADR-0001) and a feature plugs in by assigning its closure at launch.
struct AppActions {
    /// FRD-003 Library panel.
    var openLibrary: (@MainActor () -> Void)?
    /// FRD-005 Save Clipboard.
    var saveClipboard: (@MainActor () -> Void)?
    /// FRD-006 Shelf.
    var toggleShelf: (@MainActor () -> Void)?
    /// FR-008-03 Settings window; assigned in `SettingsHook.swift`.
    var openSettings: (@MainActor () -> Void)?
    /// FRD-002 FR-002-12 "import screenshots from the last 30 days"; called from onboarding when the box is checked.
    var importRecentScreenshots: (@MainActor () -> Void)?
}
