import AppKit
import FlotsamBase
import FlotsamCapture
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
    /// Retained for the life of the app; the poll timer only holds it weakly.
    private(set) var capture: ClipboardCapture?
    private var observers: [any NSObjectProtocol] = []

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
            startCapture(database: opened)
        case .failure(let error): await reporter.report(error, origin: .background)
        }
    }

    /// FRD-001: wires capture to the database and starts the poll. Wake and activation each force one immediate
    /// check (FR-001-02 b, c); the launch check runs inside `start()` (FR-001-02 d).
    private func startCapture(database: FlotsamDatabase) {
        let settings = SettingsStore.standard()
        let capture = ClipboardCapture(
            pasteboard: SystemPasteboard(), sourceApps: SystemSourceApps(), ownWrites: OwnWriteLedger(),
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
}
