import AppKit
import FlotsamBase
import FlotsamCapture
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
    /// The one settings store; every reader and writer shares it (ADR-0009).
    let settings: SettingsStore
    /// Retained for the life of the app; the poll timer only holds it weakly.
    private(set) var capture: ClipboardCapture?
    /// The Library panel (FR-003-01). Nil until the database has opened; the menu item is disabled until then.
    private(set) var library: LibraryPanelController?
    private var libraryHotkey: LibraryHotkey?
    private var observers: [any NSObjectProtocol] = []

    init() {
        let presenter = ErrorPresenterAdapter(dataFolder: Self.dataFolder)
        self.presenter = presenter
        let reporter = ErrorReporter(presenter: presenter)
        self.reporter = reporter
        settings = SettingsStore(store: UserDefaultsStore()) { keyName in
            let error = FlotsamError(.setDat001, "setting \(keyName) was invalid; its default is in use")
            Task { await reporter.report(error, origin: .background) }
        }
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
        let capture = ClipboardCapture(
            pasteboard: SystemPasteboard(), sourceApps: SystemSourceApps(), ownWrites: ownWrites,
            ingest: IngestActor(database: database, settings: settings), settings: settings, reporter: reporter,
            // The ignored-apps list and its defaults are one definition in FRD-008 FR-008-11; no code home exists
            // yet, so nothing is ignored until the Settings builder wires `privacy.ignoredApps` here.
            ignoredApps: { [] })
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
        let preferences = SettingsLibraryPreferences(settings: settings)
        let probe = AccessibilityPermissionProbe()
        let frontmost = WorkspaceFrontmostAppProvider()
        let paster = PasteService(
            store: database, pasteboard: SystemPasteboard(), files: LocalFileSystem(), frontmost: frontmost,
            accessibility: probe, keys: CGEventKeyPoster(), clock: SystemClock(), ownWrites: ownWrites)

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
        let capture = capture
        let controller = LibraryPanelController(
            source: database, paster: paster, preferences: preferences, effects: effects, frontmost: frontmost,
            captureNow: { capture?.captureNow() })
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

    /// Capture and paste share one ledger so a paste-back is not re-captured as a new copy (FR-001-03).
    private let ownWrites = OwnWriteLedger()
}
