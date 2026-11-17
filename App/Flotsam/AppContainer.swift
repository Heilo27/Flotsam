import AppKit
import FlotsamBase
import FlotsamCapture
import FlotsamLibrary
import FlotsamPaste
import FlotsamShortcuts
import FlotsamStorage
import FlotsamTriggers
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
    private(set) var capture: FlotsamCapture.ClipboardCapture?
    /// The Library panel (FR-003-01). Nil until the database has opened; the menu item is disabled until then.
    private(set) var library: LibraryPanelController?
    /// The one registration path for every global and item hotkey (FR-005-01). Created at launch so Settings can hold
    /// it; the bindings are applied once the Library exists (`startLibrary`).
    let shortcuts = ShortcutRegistry(registrar: CarbonHotkeyRegistrar(), systemHotkeys: SymbolicHotkeyProvider())
    private var unsubscribeShortcuts: (@Sendable () -> Void)?
    private var unsubscribeItemEvents: (@Sendable () -> Void)?
    private var itemHotkeyAction: ItemHotkeyAction?
    /// The typed-trigger engine (FR-005-10). Nil until the database has opened. Retained: its loops run until `stop()`.
    private(set) var triggerEngine: TriggerEngine?
    /// Asks the tap thread to clear the typed word (FR-005-11): shared by the tap adapter, the keyboard environment and
    /// the wake and session observers below, so every "the word is no longer trustworthy" event takes one path.
    private let triggerReset = TriggerResetSignal()
    private var unsubscribeTriggerSetting: (@Sendable () -> Void)?
    /// One resync reads the item bindings at a time; a change that arrives meanwhile queues exactly one more.
    private var itemSyncRunning = false
    private var itemSyncPending = false
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
            permissions: permissions, shortcuts: shortcuts, storage: storage, dataFolder: Self.dataFolder,
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
            startLibrary(database: opened)
        case .failure(let error): await reporter.report(error, origin: .background)
        }
    }

    /// FRD-001: wires capture to the database and starts the poll. Wake and activation each force one immediate
    /// check (FR-001-02 b, c); the launch check runs inside `start()` (FR-001-02 d).
    private func startCapture(database: FlotsamDatabase) {
        let settings = settings
        let capture = FlotsamCapture.ClipboardCapture(
            pasteboard: SystemPasteboard(), sourceApps: SystemSourceApps(), ownWrites: ownWrites,
            ingest: IngestActor(database: database, settings: settings), settings: settings, reporter: reporter,
            // FR-008-11: the list is read per copy, so Settings edits apply without a relaunch.
            ignoredApps: { Set(settings.value(SettingKeys.privacyIgnoredApps).identifiers) })
        self.capture = capture
        // FR-005-06: the Save Clipboard hotkey and the menu row both run this one action.
        let presenter = presenter
        let saveClipboard = SaveClipboardAction(saver: capture, hud: { presenter.showHUD(message: $0) })
        actions.saveClipboard = { Task { await saveClipboard.run() } }

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
        let keys = CGEventKeyPoster()
        let pasteboard = SystemPasteboard()
        let paster = PasteService(
            store: database, pasteboard: pasteboard, files: LocalFileSystem(), frontmost: frontmost,
            accessibility: probe, keys: keys, clock: SystemClock(), ownWrites: ownWrites)

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

        startShortcuts(openLibrary: { [weak controller] in controller?.toggle() })
        startItemHotkeys(database: database, paster: paster, frontmost: frontmost)
        startTriggers(database: database, paster: paster, pasteboard: pasteboard, keys: keys)
    }

    /// FRD-005 typed triggers: builds the engine over the adapters and starts it. Starting never installs a tap by
    /// itself and never prompts (FR-005-10): the engine installs one only when triggers are on, an item has a trigger and
    /// both permissions are already granted. The prompts come from `userDidSaveTrigger()` and `userDidEnableTriggers()`.
    private func startTriggers(
        database: FlotsamDatabase, paster: PasteService, pasteboard: SystemPasteboard, keys: CGEventKeyPoster
    ) {
        let clock = SystemClock()
        let keyboard = SystemKeyboardEnvironment(resetSignal: triggerReset)
        let snapshot = TriggerSnapshotStore()
        let ownBundleId = Bundle.main.bundleIdentifier ?? FlotsamLog.fallbackSubsystem
        let expander = TriggerExpander(
            store: database, pasteboard: pasteboard, files: LocalFileSystem(), codec: AppKitRichTextCodec(),
            preserver: ClipboardPreserver(pasteboard: pasteboard, ownWrites: ownWrites, clock: clock),
            ownWrites: ownWrites, paste: paster, keys: keys, keyboard: keyboard, snapshot: snapshot,
            permissions: permissions, reporter: reporter, clock: clock, ownBundleId: ownBundleId)
        let engine = TriggerEngine(
            source: EventTapKeySource(resetSignal: triggerReset), snapshot: snapshot, bindings: database,
            settings: settings, bus: database.events, expander: expander, keyboard: keyboard,
            permissions: permissions, reporter: reporter, clock: clock, resetSignal: triggerReset,
            ownBundleId: ownBundleId)
        triggerEngine = engine
        Task { await engine.start() }

        // The permission prompt appears when the user turns triggers on, never at launch (FR-005-10).
        let settings = settings
        unsubscribeTriggerSetting = settings.subscribe { change in
            guard change.name == SettingKeys.triggersEnabled.name else { return }
            Task { @MainActor in
                if settings.value(SettingKeys.triggersEnabled) { await engine.userDidEnableTriggers() }
            }
        }

        // Waking, or this session coming back after fast user switching, drops the typed word and re-verifies the tap
        // at once instead of at the next watchdog tick (FR-005-19). Stopping happens in `stopTriggers()`.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in await engine.systemDidResume() }
                })
        }
    }

    /// Quit: removes the tap and stops the engine's loops (FR-005-03, FR-005-10).
    func stopTriggers() {
        unsubscribeTriggerSetting?()
        unsubscribeTriggerSetting = nil
        triggerEngine?.stop()
    }

    /// Item hotkeys (FR-005-05): bound from the stored bindings at launch, re-synced when items change or go (FR-005-22),
    /// and off while any Flotsam window (the Library panel, Settings) is key.
    private func startItemHotkeys(database: FlotsamDatabase, paster: PasteService, frontmost: any FrontmostAppProvider) {
        let reporter = reporter
        itemHotkeyAction = ItemHotkeyAction(
            paster: paster, frontmost: frontmost,
            report: { error in Task { await reporter.report(error, origin: .userInitiated) } })
        syncItemHotkeys(database: database)

        unsubscribeItemEvents = database.events.subscribe { [weak self] event in
            // Delivery is synchronous and may be off the main actor; the registry is main-actor.
            Task { @MainActor in
                guard let self else { return }
                if case .itemsDeleted(let ids) = event {
                    for id in ids { self.shortcuts.remove(.item(id)) }
                }
                self.syncItemHotkeys(database: database)
            }
        }

        // Any key window of this app is a Flotsam window. After a resign the next window may already be taking over, so
        // the state is read once the run loop has settled (FR-005-05).
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.shortcuts.setItemHotkeysSuspended(NSApp.keyWindow != nil) }
                })
        }
    }

    /// Reads the stored item hotkeys and makes the registry match them. Overlapping calls coalesce, so an older read
    /// can never be applied after a newer one.
    private func syncItemHotkeys(database: FlotsamDatabase) {
        if itemSyncRunning {
            itemSyncPending = true
            return
        }
        itemSyncRunning = true
        Task { @MainActor in
            repeat {
                itemSyncPending = false
                switch await database.itemBindings() {
                case .success(let bindings):
                    guard let action = itemHotkeyAction else { break }
                    reportShortcutErrors(shortcuts.syncItemHotkeys(bindings.hotkeys) { id in { Task { await action.run(itemId: id) } } })
                case .failure(let error):
                    await reporter.report(error, origin: .background)
                }
            } while itemSyncPending
            itemSyncRunning = false
        }
    }

    /// Points the registry's three global actions at their owners and binds them from Settings (FR-005-01). Save
    /// Clipboard and Toggle Shelf go through `actions`, so an owner that plugs in later is picked up at the next press;
    /// until then the press does nothing (FR-005-07). A rebinding in Settings, or the Shelf switch, takes effect at once.
    private func startShortcuts(openLibrary: @escaping @MainActor () -> Void) {
        shortcuts.setAction(.openLibrary, openLibrary)
        shortcuts.setAction(.saveClipboard) { [weak self] in self?.actions.saveClipboard?() }
        shortcuts.setAction(.toggleShelf) { [weak self] in self?.actions.toggleShelf?() }
        reportShortcutErrors(shortcuts.applyGlobalSettings(settings))

        let names: Set<String> = [
            SettingKeys.shortcutsOpenLibrary.name, SettingKeys.shortcutsSaveClipboard.name,
            SettingKeys.shortcutsToggleShelf.name, SettingKeys.shelfEnabled.name,
        ]
        unsubscribeShortcuts = settings.subscribe { [weak self] change in
            guard names.contains(change.name) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.reportShortcutErrors(self.shortcuts.applyGlobalSettings(self.settings))
            }
        }
        // macOS can drop a hotkey registration across sleep; a refused one is retried at wake (FR-005-03).
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reportShortcutErrors(self.shortcuts.retryFailed())
                }
            })
    }

    private func reportShortcutErrors(_ errors: [FlotsamError]) {
        let reporter = reporter
        for error in errors { Task { await reporter.report(error, origin: .background) } }
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
    /// FR-008-03 Settings window; assigned by `installSettings`. The menu row and the Library both call this one closure.
    var openSettings: (@MainActor () -> Void)?
    /// FRD-002 FR-002-12 "import screenshots from the last 30 days"; called from onboarding when the box is checked.
    var importRecentScreenshots: (@MainActor () -> Void)?
}
