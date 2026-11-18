import AppKit
import FlotsamBase
import FlotsamCapture
import FlotsamLibrary
import FlotsamPaste
import FlotsamPayload
import FlotsamScreenshots
import FlotsamShelf
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
    /// The Shelf panel (FR-006-01). Nil until the database has opened; the menu item is disabled until then.
    private(set) var shelf: ShelfPanelController?
    private var libraryHotkey: LibraryHotkey?
    private var shelfHotkey: LibraryHotkey?
    private var unsubscribeHotkey: (@Sendable () -> Void)?
    private var unsubscribeShelfHotkey: (@Sendable () -> Void)?
    private var unsubscribeScreenshots: (@Sendable () -> Void)?
    /// Retained for the life of the app (FRD-002).
    private(set) var screenshots: ScreenshotWatcher?
    private var observers: [any NSObjectProtocol] = []
    /// Capture and paste share one ledger so a paste-back is not re-captured as a new copy (FR-001-03).
    private let ownWrites = OwnWriteLedger()
    /// The Settings window (FR-008-03). Retained here; `actions.openSettings` holds it weakly.
    private var settingsWindow: SettingsWindowController?

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

    /// Builds the Settings window over this container's objects and points `actions.openSettings` at it, so every
    /// "Open Settings" caller (the menu row, the Library, a Notice) takes the one path (FR-008-03). The window is
    /// created at first use; the database it reads is asked for on each call, because it opens after launch.
    func installSettings(showSetupGuide: @escaping @MainActor @Sendable () -> Void) {
        let reporter = reporter
        let presenter = presenter
        let settings = settings
        let permissions = permissions
        let storage = SettingsStorage(database: { [weak self] in self?.database })
        let loginItem = loginItem
        let environment = SettingsEnvironment(
            settings: settings, login: loginItem,
            openLoginItems: { loginItem.openLoginItemsSettings() },
            permissions: permissions, storage: storage, dataFolder: Self.dataFolder,
            revealDataFolder: { NSWorkspace.shared.open(Self.dataFolder) },
            report: { error in Task { await reporter.report(error, origin: .userInitiated) } },
            hud: { message in presenter.showHUD(message: message) },
            showSetupGuide: showSetupGuide,
            copyDiagnostics: {
                await SettingsDiagnostics.copy(settings: settings, probe: permissions, storage: storage, reporter: reporter)
            })
        let window = SettingsWindowController(env: environment)
        settingsWindow = window
        actions.openSettings = { [weak window] in window?.openSettings() }
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
            // The Library and the Shelf paste through one service and read one frontmost app (FR-006-08).
            let frontmost = WorkspaceFrontmostAppProvider()
            let paster = PasteService(
                store: opened, pasteboard: SystemPasteboard(), files: LocalFileSystem(), frontmost: frontmost,
                accessibility: permissions, keys: CGEventKeyPoster(), clock: SystemClock(), ownWrites: ownWrites)
            startShelf(database: opened, paster: paster, frontmost: frontmost)
            startLibrary(database: opened, paster: paster, frontmost: frontmost)
            startScreenshots(database: opened)
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

    /// FRD-002: wires screenshot pickup. The watcher itself reads `screenshots.enabled`, so with the setting off it
    /// creates no stream, no timer and touches no folder (FR-002-05).
    private func startScreenshots(database: FlotsamDatabase) {
        let reporter = reporter
        let settings = settings
        let watcher = ScreenshotWatcher(
            fileSystem: LocalFileSystem(), preferences: SystemScreenCapturePreferences(),
            home: FileManager.default.homeDirectoryForCurrentUser, clock: SystemClock(),
            eventSource: FSEventsFolderSource(), settings: settings,
            ingest: IngestActor(database: database, settings: settings),
            watermarkStore: DatabaseWatermarkStore(database: database),
            report: { error in await reporter.report(error, origin: .background) },
            clear: { code in await reporter.clearNotices(code: code) })
        screenshots = watcher

        let watched: Set<String> = [
            SettingKeys.screenshotsEnabled.name, SettingKeys.screenshotsFolderOverride.name, SettingKeys.captureMode.name,
        ]
        unsubscribeScreenshots = settings.subscribe { change in
            guard watched.contains(change.name) else { return }
            Task { await watcher.settingsDidChange() }
        }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers += [
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { await watcher.didWake() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { await watcher.didBecomeActive() }
            },
        ]
        // FR-002-12: onboarding's checkbox and Settings' button both call this. The count is not shown here.
        actions.importRecentScreenshots = { Task { _ = await watcher.importRecent() } }
        Task { await watcher.start() }
    }

    /// FRD-006: builds the Shelf over the opened database and points `actions.toggleShelf` at it (FR-006-03c). The Shelf
    /// pastes through the Library's `PasteService` (FR-006-08) and reads Missing from the same row flag (FR-006-14).
    private func startShelf(database: FlotsamDatabase, paster: PasteService, frontmost: WorkspaceFrontmostAppProvider) {
        let reporter = reporter
        let capture = capture
        let effects = ShelfEffects(
            report: { error in Task { await reporter.report(error, origin: .userInitiated) } },
            captureNow: { capture?.captureNow() },
            confirmDelete: { message in Self.confirmDelete(message) })
        let controller = ShelfPanelController(
            settings: settings, frontmost: frontmost, thumbnail: { await database.thumbnail(itemId: $0, size: .grid) },
            makeModel: { host in
                ShelfModel(
                    source: database, paster: ShelfPasteAdapter(service: paster), host: host, events: database.events,
                    details: database, effects: effects)
            })
        shelf = controller
        actions.toggleShelf = { [weak controller] in controller?.toggle() }

        // The Toggle Shelf hotkey (FR-006-03c, FR-005-07): unbound by default, and unregistered while the Shelf is off.
        // `LibraryHotkey` is the one registration path; only the chord it reads differs.
        let hotkey = LibraryHotkey(
            registrar: CarbonHotkeyRegistrar(), preferences: SettingsShelfHotkeyPreferences(settings: settings)
        ) { [weak controller] in controller?.toggle(.hotkey) }
        if case .failure(let error) = hotkey.apply() {
            Task { await reporter.report(error, origin: .background) }
        }
        shelfHotkey = hotkey
        let watched: Set<String> = [SettingKeys.shortcutsToggleShelf.name, SettingKeys.shelfEnabled.name]
        unsubscribeShelfHotkey = settings.subscribe { [weak hotkey] change in
            guard watched.contains(change.name) else { return }
            Task { @MainActor in
                if case .failure(let error) = hotkey?.apply() { await reporter.report(error, origin: .background) }
            }
        }
    }

    /// The delete confirmation (FR-004-09) as a modal alert; the Shelf's panel is not key, so a sheet has no parent.
    private static func confirmDelete(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: ShelfText.string(ShelfText.buttonDelete))
        alert.addButton(withTitle: ShelfText.string(ShelfText.buttonCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Builds the Library stack over the opened database and registers its hotkey (FR-003-01, FR-005-01).
    private func startLibrary(database: FlotsamDatabase, paster: PasteService, frontmost: WorkspaceFrontmostAppProvider) {
        let reporter = reporter
        let probe = permissions

        // FRD-004: the coordinator and the organizer need each other (rejected input shows inline), so the organizer is
        // handed over after both exist.
        let organize = OrganizeCoordinator(
            report: { error, origin in Task { await reporter.report(error, origin: origin) } },
            loadContent: { await database.content(of: $0) },
            shortcutAndTrigger: { [weak self] ids in self?.actions.editShortcutAndTrigger?(ids) })
        let organizer = LibraryOrganizer(
            store: database, classifiers: .live, report: { [weak organize] error in organize?.surface(error) })
        organize.organizer = organizer

        let effects = LibraryEffects(
            report: { error in Task { await reporter.report(error, origin: .userInitiated) } },
            reveal: { paths in
                NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            },
            openSettings: { [weak self] in self?.actions.openSettings?() },
            // Pin, tags, note, edit, delete and ungroup are FRD-004; ⌘K reaches FRD-005 through `actions`.
            external: { [weak organize] command, ids in organize?.perform(command, ids: ids) },
            isAccessibilityTrusted: { probe.isAccessibilityTrusted })
        let capture = capture
        let controller = LibraryPanelController(
            source: database, paster: paster, preferences: SettingsLibraryPreferences(settings: settings),
            effects: effects, organizer: organizer, organize: organize, frontmost: frontmost,
            // Flush a copy made in the last poll interval before the Library lists items (FR-003-02).
            captureNow: { capture?.captureNow() })
        library = controller
        // Only one Flotsam panel is open at a time: opening the Library hides the Shelf (FR-006-04).
        actions.openLibrary = { [weak controller, weak self] in
            self?.shelf?.libraryOpened()
            controller?.toggle()
        }

        let hotkey = LibraryHotkey(
            registrar: CarbonHotkeyRegistrar(), preferences: SettingsLibraryHotkeyPreferences(settings: settings)
        ) { [weak controller, weak self] in
            self?.shelf?.libraryOpened()
            controller?.toggle()
        }
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
    /// FRD-005 ⌘K in the Library: edit the selected item's shortcut and trigger. Inert until FRD-005 fills it.
    var editShortcutAndTrigger: (@MainActor ([UUID]) -> Void)?
    /// FRD-006 Shelf.
    var toggleShelf: (@MainActor () -> Void)?
    /// FR-008-03 Settings window; assigned by `installSettings`. The menu row and the Library both call this one closure.
    var openSettings: (@MainActor () -> Void)?
    /// FRD-002 FR-002-12 "import screenshots from the last 30 days"; called from onboarding when the box is checked.
    var importRecentScreenshots: (@MainActor () -> Void)?
}
