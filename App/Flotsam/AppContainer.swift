import AppKit
import FlotsamBase
import FlotsamCapture
import FlotsamLibrary
import FlotsamPaste
import FlotsamPayload
import FlotsamScreenshots
import FlotsamShelf
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
    /// The resume point of an unfinished onboarding; progress, not a preference, so it is not in the registry.
    let onboardingProgress: OnboardingProgress
    /// The data folder, the settings store and the secure-item services this launch uses (TASK-519).
    private let environment: AppEnvironment
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
    /// The menu-bar item's frame, set by `StatusItemController`; the Shelf anchors under it (FR-006-05c).
    var menuBarIconFrame: (@MainActor () -> CGRect?)?
    private var unsubscribeScreenshots: (@Sendable () -> Void)?
    /// Retained for the life of the app (FRD-002).
    private(set) var screenshots: ScreenshotWatcher?
    /// The "Import recent screenshots" entry: holds a click that arrives before the watcher is wired and reports a
    /// database that failed to open (FR-002-12).
    private let importRecent: ImportRecentCoordinator
    /// The one registration path for every global and item hotkey (FR-005-01). Created at launch so Settings can hold
    /// it; the bindings are applied once the Library exists (`startLibrary`).
    let shortcuts = ShortcutRegistry(registrar: CarbonHotkeyRegistrar(), systemHotkeys: SymbolicHotkeyProvider())
    private var unsubscribeShortcuts: (@Sendable () -> Void)?
    private var unsubscribeItemEvents: (@Sendable () -> Void)?
    private var itemHotkeyAction: ItemHotkeyAction?
    /// The typed-trigger engine (FR-005-10). Nil until the database has opened. Retained: its loops run until `stop()`.
    private(set) var triggerEngine: TriggerEngine?
    /// Asks the tap thread to clear the typed word (FR-005-11): shared by the tap adapter and the engine, whose
    /// `frontmostApplicationDidChange()` and `systemDidResume()` are the app's "the word is no longer trustworthy" paths.
    private let triggerReset = TriggerResetSignal()
    private var unsubscribeTriggerSetting: (@Sendable () -> Void)?
    /// Told when the engine's status changes, so the menu-bar icon can show or clear the tap's warning dot (FR-005-19).
    /// Set by the status item; read through the engine, so it needs no engine to exist yet.
    var onTriggerStatusChange: (@MainActor () -> Void)?
    /// True while the tap is latched off after repeated disablement (FR-005-19).
    var showsTriggerWarning: Bool { triggerEngine?.showsWarningDot ?? false }
    /// One resync reads the item bindings at a time; a change that arrives meanwhile queues exactly one more.
    private var itemSyncRunning = false
    private var itemSyncPending = false
    private var observers: [any NSObjectProtocol] = []
    private var permissionLogger: PermissionTransitionLogger?
    private var permissionObserver: (any NSObjectProtocol)?
    /// Capture and paste share one ledger so a paste-back is not re-captured as a new copy (FR-001-03).
    private let ownWrites = OwnWriteLedger()
    /// Seals and opens secure items with the Keychain key (ADR-0011). Capture seals with it, the database asks it whether
    /// the key is readable (an unreadable one shows the row as unavailable), and `secureAccess` opens with it.
    private let secureVault: SecureClipVault
    /// Authenticate-then-decrypt for secure items (FR-003-23, FR-006-21); the one instance Paste and the Shelf share, so
    /// "the owner confirms every time" is one rule.
    private let secureAccess: SecureClipAccess
    /// The one recurring timer's tick (S5, ADR-0004): the pasteboard poll fires it, and the tap watchdog and the
    /// screenshot folder re-resolve run on it instead of owning timers.
    private let pollTick = PollTick()
    /// The Settings window (FR-008-03). Retained here; `actions.openSettings` holds it weakly.
    private var settingsWindow: SettingsWindowController?
    /// The shortcut-and-trigger editor (FR-005-09). Nil until the database has opened.
    private var itemEditor: ItemBindingsEditorWindowController?

    init() {
        let environment = AppEnvironment.launch()
        self.environment = environment
        onboardingProgress = OnboardingProgress(store: environment.settingsStore)
        let presenter = ErrorPresenterAdapter(dataFolder: environment.dataFolder)
        let reporter = ErrorReporter(presenter: presenter)
        self.presenter = presenter
        self.reporter = reporter
        importRecent = ImportRecentCoordinator(hud: { message in presenter.showHUD(message: message) })
        // FR-008-11: before anything reads the list, so a never-customised old default does not keep the password managers
        // ignored.
        IgnoredAppsMigration.run(on: environment.settingsStore)
        settings = SettingsStore(store: environment.settingsStore) { _ in
            let error = FlotsamError(.setDat001, "A stored setting was invalid and was reset to its default")
            Task { await reporter.report(error, origin: .background) }
        }
        permissions = SystemPermissionProbe()
        let vault = SecureClipVault(store: environment.secureKeys)
        secureVault = vault
        secureAccess = SecureClipAccess(vault: vault, authenticator: environment.authenticator)
        loginItem = LoginItemController(service: SMLoginItemService())
        // FR-002-12 / FR-008-04: the action exists from construction, so a click before pickup is wired is never a no-op.
        actions.importRecentScreenshots = { [weak self] in self?.importRecent.request() }
        Task { await openDatabase() }
        startPermissionLogging()
    }

    /// FR-000-11: logs a permission flipping. The first `check()` records the launch state as the baseline; each return
    /// to the app (typically from System Settings) logs whatever changed since.
    private func startPermissionLogging() {
        let logger = PermissionTransitionLogger(probe: permissions)
        permissionLogger = logger
        logger.check()
        permissionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { logger.check() }
        }
    }

    /// The screenshot settings as onboarding may show them: read-only. Only Settings › General writes them (FR-008-17).
    var screenshotPickup: (enabled: Bool, folderName: String?) {
        (settings.value(SettingKeys.screenshotsEnabled),
         Pickers.folderName(of: settings.value(SettingKeys.screenshotsFolderOverride)))
    }

    /// Builds the Settings window over this container's objects and points `actions.openSettings` at it, so every
    /// "Open Settings" caller (the menu row, the Library) takes the one path (FR-008-03). No Notice or alert has an
    /// "Open Settings" action today (a `Notice` carries a code and a message only); one added later must call
    /// `actions.openSettings`. The window is created at first use; the database it reads is asked for on each call, because it opens after launch.
    func installSettings(showSetupGuide: @escaping @MainActor @Sendable () -> Void) {
        let reporter = reporter
        let presenter = presenter
        let settings = settings
        let permissions = permissions
        let storage = SettingsStorage(database: { [weak self] in self?.database })
        let loginItem = loginItem
        let dataFolder = environment.dataFolder
        let settingsEnvironment = SettingsEnvironment(
            settings: settings, login: loginItem,
            openLoginItems: { loginItem.openLoginItemsSettings() },
            permissions: permissions, shortcuts: shortcuts, storage: storage, dataFolder: dataFolder,
            revealDataFolder: { NSWorkspace.shared.open(dataFolder) },
            report: { error in Task { await reporter.report(error, origin: .userInitiated) } },
            hud: { message in presenter.showHUD(message: message) },
            showSetupGuide: showSetupGuide,
            importRecentScreenshots: { [weak self] in self?.actions.importRecentScreenshots?() },
            copyDiagnostics: {
                await SettingsDiagnostics.copy(settings: settings, probe: permissions, storage: storage, reporter: reporter)
            })
        let window = SettingsWindowController(env: settingsEnvironment)
        settingsWindow = window
        actions.openSettings = { [weak self, weak window] in
            self?.hideLibraryBeforeWindowOpens()
            window?.openSettings()
        }
    }

    /// The App-side home of "a Flotsam window opens, so the Library hides" (FR-003-02, TASK-524). Every opener of the
    /// Settings window, the item editor and the setup guide runs it before fronting the window: the Library's own ⌘, and
    /// ⌘K, the menu-bar "Settings…" row, and "Show Setup Guide…" (AppDelegate). A no-op when the Library is already
    /// hidden or not built yet. The Library's `perform` also hides first (LibraryViewModel.perform), for the
    /// package-level guarantee that holds without the App; both end at the same idempotent `hidePanel`.
    func hideLibraryBeforeWindowOpens() { library?.hidePanel() }

    private func openDatabase() async {
        switch await FlotsamDatabase.open(folder: environment.dataFolder, secureVault: secureVault) {
        case .success(let opened):
            database = opened
            startCapture(database: opened)
            // The Library and the Shelf paste through one service and read one frontmost app (FR-006-08).
            let frontmost = WorkspaceFrontmostAppProvider()
            let pasteboard = SystemPasteboard()
            let keys = CGEventKeyPoster()
            let paster = PasteService(
                store: opened, pasteboard: pasteboard, files: LocalFileSystem(), frontmost: frontmost,
                accessibility: permissions, keys: keys, clock: SystemClock(), ownWrites: ownWrites, secureAccess: secureAccess)
            startShelf(database: opened, paster: paster, frontmost: frontmost)
            startLibrary(database: opened, paster: paster, pasteboard: pasteboard, keys: keys, frontmost: frontmost)
            startScreenshots(database: opened)
        case .failure(let error):
            await reporter.report(error, origin: .background)
            // No library means nothing can be imported: a click that was waiting, and every later one, shows why.
            importRecent.unavailable(error)
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
            ignoredApps: { Set(settings.value(SettingKeys.privacyIgnoredApps).identifiers) },
            access: SystemPasteboardAccess(), vault: secureVault, pollTick: pollTick)
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
            clear: { code in await reporter.clearNotices(code: code) }, pollTick: pollTick)
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
        importRecent.ready { hud in await watcher.importRecentAnnouncing(hud: hud) }
        Task { await watcher.start() }
    }

    /// What a drag-out session needs, for the Shelf (FR-006-10) and the Library's rows (FR-003-45): the cards' content,
    /// a paste counted per accepted card, the file system, the secure-item gate and the error report. One home, so the
    /// two surfaces cannot drift.
    private func dragOutPorts(database: FlotsamDatabase, report: @escaping @MainActor (FlotsamError) -> Void) -> ShelfDragOut.Ports {
        .init(
            content: { await database.content(of: $0) }, recordPaste: { _ = await database.recordPaste(of: $0) },
            files: LocalFileSystem(), secureAccess: secureAccess, report: report)
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
        controller.menuBarIconFrame = { [weak self] in self?.menuBarIconFrame?() }
        // FR-006-10: drag-out reads the cards' content and counts a paste per accepted card.
        controller.dragOut.ports = dragOutPorts(database: database, report: effects.report)
        // FR-006-13: a drop is an ingest path. It goes through the same classifier and ingest actor as clipboard
        // capture; the controller reads the drag pasteboard and calls this.
        controller.dropService = ShelfDropService(
            ingest: IngestActor(database: database, settings: settings), reporter: reporter,
            dropCompleted: { [weak controller] in await controller?.dropCompleted() })
        // Only one Flotsam panel is open at a time: showing the Shelf hides the Library (FR-006-04). The reverse is
        // `actions.openLibrary`, which the Library hotkey also runs.
        controller.onReveal = { [weak self] in self?.library?.hidePanel() }
        actions.toggleShelf = { [weak controller] in controller?.toggle() }

        // The Toggle Shelf hotkey (FR-006-03c, FR-005-07) goes through the one registry (`startShortcuts` binds it from
        // Settings and unregisters it while the Shelf is off). The hotkey passes its own trigger so the reveal log
        // tells a hotkey toggle from the menu item.
        shortcuts.setAction(.toggleShelf) { [weak controller] in controller?.toggle(.hotkey) }
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
    private func startLibrary(
        database: FlotsamDatabase, paster: PasteService, pasteboard: SystemPasteboard, keys: CGEventKeyPoster,
        frontmost: WorkspaceFrontmostAppProvider
    ) {
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

        // One snapshot-expand-write-restore home for item hotkeys and typed triggers (FR-005-16, FR-005-17).
        let clock = SystemClock()
        let files = LocalFileSystem()
        let codec = AppKitRichTextCodec()
        let preserver = ClipboardPreserver(pasteboard: pasteboard, ownWrites: ownWrites, clock: clock)
        let expansion = PasteExpansion(
            pasteboard: pasteboard, files: files, codec: codec, preserver: preserver, ownWrites: ownWrites, clock: clock)

        let presenter = presenter
        let editor = ItemBindingsEditorWindowController(
            services: ItemBindingsEditorServices(
                database: database, registry: shortcuts,
                // The engine is built after this; read at call time (FR-005-10: the prompt follows the first saved trigger).
                didSaveTrigger: { [weak self] in await self?.triggerEngine?.userDidSaveTrigger() },
                report: { error in Task { await reporter.report(error, origin: .userInitiated) } },
                hud: { presenter.showHUD(message: $0) }))
        itemEditor = editor

        let effects = LibraryEffects(
            report: { error in Task { await reporter.report(error, origin: .userInitiated) } },
            reveal: { paths in
                NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            },
            openSettings: { [weak self] in self?.actions.openSettings?() },
            // Pin, tags, note, edit, delete and ungroup are FRD-004; ⌘K reaches FRD-005 through `actions`.
            external: { [weak organize] command, ids in organize?.perform(command, ids: ids) },
            isAccessibilityTrusted: { probe.isAccessibilityTrusted },
            openAccessibilitySettings: { probe.openSystemSettings(.accessibility) })
        let capture = capture
        let controller = LibraryPanelController(
            source: database, paster: paster, preferences: SettingsLibraryPreferences(settings: settings),
            effects: effects, organizer: organizer, organize: organize, frontmost: frontmost,
            events: database.events,
            // Flush a copy made in the last poll interval before the Library lists items (FR-003-02).
            captureNow: { capture?.captureNow() })
        library = controller
        // FR-003-45: dragging a row out reads the same content and counts a paste per accepted row.
        controller.dragOut.ports = dragOutPorts(database: database, report: { error in Task { await reporter.report(error, origin: .userInitiated) } })
        // Only one Flotsam panel is open at a time: opening the Library hides the Shelf (FR-006-04).
        actions.openLibrary = { [weak controller, weak self] in
            self?.shelf?.libraryOpened()
            controller?.toggle()
        }

        // The Library reaches the shortcut-and-trigger editor through `actions` (FR-005-09) with the one item it
        // resolved (`LibraryExternalCommand.shortcutEditorTarget`: exactly one, and not a secure item), so the app
        // opens the editor for the id it is handed and decides nothing itself. The Library hides first, as for every
        // Flotsam window that opens from it (TASK-524).
        actions.editShortcutAndTrigger = { [weak self, weak editor] ids in
            guard let id = ids.first else { return }
            self?.hideLibraryBeforeWindowOpens()
            editor?.open(itemId: id)
        }
        startShortcuts(openLibrary: { [weak self] in self?.actions.openLibrary?() })
        startItemHotkeys(database: database, paster: paster, expansion: expansion, frontmost: frontmost)
        startTriggers(
            database: database, paster: paster, pasteboard: pasteboard, keys: keys, files: files, codec: codec,
            preserver: preserver)
    }

    /// FRD-005 typed triggers: builds the engine over the adapters and starts it. Starting never installs a tap by
    /// itself and never prompts (FR-005-10): the engine installs one only when triggers are on, an item has a trigger and
    /// both permissions are already granted. The prompts come from `userDidSaveTrigger()` and `userDidEnableTriggers()`.
    private func startTriggers(
        database: FlotsamDatabase, paster: PasteService, pasteboard: SystemPasteboard, keys: CGEventKeyPoster,
        files: LocalFileSystem, codec: AppKitRichTextCodec, preserver: ClipboardPreserver
    ) {
        let clock = SystemClock()
        let keyboard = SystemKeyboardEnvironment()
        let snapshot = TriggerSnapshotStore()
        let ownBundleId = Bundle.main.bundleIdentifier ?? FlotsamLog.fallbackSubsystem
        let expander = TriggerExpander(
            store: database, pasteboard: pasteboard, files: files, codec: codec, preserver: preserver,
            ownWrites: ownWrites, paste: paster, keys: keys, keyboard: keyboard, snapshot: snapshot,
            permissions: permissions, reporter: reporter, clock: clock, ownBundleId: ownBundleId)
        let engine = TriggerEngine(
            source: EventTapKeySource(resetSignal: triggerReset), snapshot: snapshot, bindings: database,
            settings: settings, bus: database.events, expander: expander, keyboard: keyboard,
            permissions: permissions, reporter: reporter, clock: clock, resetSignal: triggerReset,
            ownBundleId: ownBundleId, pollTick: pollTick)
        triggerEngine = engine
        // A change of frontmost application clears the typed word (FR-005-11).
        keyboard.onFrontmostChange = { [weak engine] in engine?.frontmostApplicationDidChange() }
        engine.onStatusChange = { [weak self] _ in self?.onTriggerStatusChange?() }
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
    private func startItemHotkeys(
        database: FlotsamDatabase, paster: PasteService, expansion: PasteExpansion, frontmost: any FrontmostAppProvider
    ) {
        let reporter = reporter
        itemHotkeyAction = ItemHotkeyAction(
            paster: paster, expansion: expansion, frontmost: frontmost,
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

    /// Points the registry's global actions at their owners and binds them from Settings (FR-005-01). Save Clipboard
    /// goes through `actions`, so an owner that plugs in later is picked up at the next press; Toggle Shelf's action is
    /// set by `startShelf`, and until it is the press does nothing (FR-005-07). A rebinding in Settings, or the Shelf
    /// switch, takes effect at once.
    private func startShortcuts(openLibrary: @escaping @MainActor () -> Void) {
        shortcuts.setAction(.openLibrary, openLibrary)
        shortcuts.setAction(.saveClipboard) { [weak self] in self?.actions.saveClipboard?() }
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
    /// FRD-005 ⌘K in the Library: edit the selected item's shortcut and trigger. Inert until FRD-005 fills it.
    var editShortcutAndTrigger: (@MainActor ([UUID]) -> Void)?
    /// FRD-006 Shelf.
    var toggleShelf: (@MainActor () -> Void)?
    /// FR-008-03 Settings window; assigned by `installSettings`. The menu row and the Library both call this one closure.
    var openSettings: (@MainActor () -> Void)?
    /// FRD-002 FR-002-12 "Import recent screenshots": onboarding's checkbox and the Settings button both call this
    /// one closure, and it shows the "Imported {n}" HUD.
    var importRecentScreenshots: (@MainActor () -> Void)?
}
