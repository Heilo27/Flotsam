import FlotsamBase
import FlotsamStorage
import Foundation

/// What pickup is doing right now, for the Settings status line (FRD-008).
public enum ScreenshotPickupStatus: Sendable, Equatable {
    case off
    /// Watching the resolved folder.
    case watching
    /// The system location is unusable, so macOS saves to the Desktop and so do we watch it (`SSP-IO-001`).
    case usingDesktop
    /// Folder access is refused (`SSP-PRM-001`); idle and retrying.
    case needsAccess
    /// The user's chosen folder is unusable (`SSP-IO-003`).
    case paused
}

/// Screenshot pickup (FRD-002): decides what is watched, hears about new files, and feeds them through the
/// ingest pipeline at a bounded pace.
///
/// All mutable state lives on this actor. Everything that can block on the file system (resolving the location,
/// listing, the stability wait, reading bytes) runs `@concurrent`, because the first read of Desktop, Documents or
/// Downloads can sit behind the system's folder-access prompt for as long as the user takes to answer it.
public actor ScreenshotWatcher {
    /// FR-002-02, FR-002-03: seconds between re-resolutions, which the access retry shares. A whole number of poll
    /// ticks (`PollTick`): the watcher owns no timer.
    public static let tickInterval: TimeInterval = 30
    /// FR-002-13.
    public static let maxInFlight = 2
    /// FR-002-07: how many times a file that was unstable is tried again.
    static let maxRetries = 3
    /// Bound on remembered imports (see `SeenFiles`).
    static let seenCapacity = 2_000

    // MARK: Collaborators

    private let fileSystem: any FileSystemPort
    private let clock: any WallClock
    private let pollTick: PollTick
    private let settings: SettingsStore
    private let resolver: ScreenshotLocationResolver
    private let scanner: ScreenshotFolderScanner
    private let importer: ScreenshotImporter
    private let eventSource: any FolderEventSource
    private let fallbackSource: PollingFolderSource
    private let watermarkStore: any ScreenshotWatermarkStore
    private let report: @Sendable (FlotsamError) async -> Void
    private let clear: @Sendable (ErrorCode) async -> Void
    private let sink: any LogSink
    /// The quiet capture cue (FR-001-30); nil shows none.
    private let cue: CaptureCue?

    // MARK: State

    public private(set) var status: ScreenshotPickupStatus = .off
    private var active = false
    private var location: ScreenshotLocation?
    private var lastMode: CaptureMode
    /// Bumped on every teardown; events and scan results from an earlier watch are discarded.
    private var generation = 0
    /// Counts the pickup sessions ended by `deactivate`. An import started in one session must not leave anything
    /// behind in a later one, so each job carries the session it was queued in.
    private var session = 0
    private var watch: (any FolderWatch)?
    private var cancelTick: (@Sendable () -> Void)?
    private var tickRunning = false

    /// The warnings of ongoing conditions, so each is raised once per change of state and cleared when it ends.
    private var raisedLocationWarning: ErrorCode?
    private var accessDenied = false
    private var inFallback = false

    private var watermark: Date?
    private var watermarkLoaded = false
    /// FR-002-08: where live file events are cut off. Moved by scans (and mode changes) only, never by an import or
    /// the tick, so a live event is judged exactly as it was before the persisted watermark started following imports.
    private var eventFloor: Date?
    /// FR-002-08: birth dates of the files the persisted watermark must not pass yet: live files queued, unstable or
    /// failed (by path), and hidden files that may still be renamed into screenshots (replaced by each listing, added
    /// by file events). Entries older than `ScreenshotSelection.holdWindow` no longer hold anything.
    private var unfinished: [String: Date] = [:]
    private var hiddenFiles: [String: Date] = [:]

    private var seen = SeenFiles(capacity: ScreenshotWatcher.seenCapacity)
    private var retry: [String: RetryEntry] = [:]
    private var queue: [ImportJob] = []
    /// Paths queued or in flight, so repeated events for one file cost one import.
    private var pending: Set<String> = []
    private var inFlight = 0
    /// Imports started and not yet fully finished (`inFlight` drops at the start of `finish`, before its watermark write
    /// and notices; this drops at its end). What `stop()` waits on.
    private var running = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by `stop()`: this watcher is finished for good and never starts pickup again.
    private var stopped = false
    private var batches: [UUID: Batch] = [:]
    /// Presses waiting on a path that was queued or in flight when their scan returned (live pickup or a reconcile
    /// got there first). The job's own result counts toward each of them when it ends.
    private var joiners: [String: [UUID]] = [:]
    /// Files live pickup (events, reconcile, retries) has already put in the library this session, so a backfill pass
    /// does not ingest them a second time. Imports by a press are left out on purpose: pressing again still runs.
    private var ingestedLive = SeenFiles(capacity: ScreenshotWatcher.seenCapacity)
    /// The in-flight `importRecentAnnouncing` run, which an overlapping call joins.
    private var announcing: Task<Void, Never>?

    public init(
        fileSystem: any FileSystemPort,
        preferences: any ScreenCapturePreferences,
        home: URL,
        clock: any WallClock,
        eventSource: any FolderEventSource,
        settings: SettingsStore,
        ingest: any ScreenshotIngesting,
        watermarkStore: any ScreenshotWatermarkStore,
        report: @escaping @Sendable (FlotsamError) async -> Void,
        clear: @escaping @Sendable (ErrorCode) async -> Void,
        pollTick: PollTick,
        cue: CaptureCue? = nil,
        sink: any LogSink = OSLogSink()
    ) {
        self.fileSystem = fileSystem
        self.clock = clock
        self.pollTick = pollTick
        self.settings = settings
        self.resolver = ScreenshotLocationResolver(fileSystem: fileSystem, preferences: preferences, home: home)
        self.scanner = ScreenshotFolderScanner(fileSystem: fileSystem, preferences: preferences)
        self.importer = ScreenshotImporter(
            fileSystem: fileSystem, stability: StabilityCheck(fileSystem: fileSystem, clock: clock), ingest: ingest)
        self.eventSource = eventSource
        self.fallbackSource = PollingFolderSource(clock: clock)
        self.watermarkStore = watermarkStore
        self.report = report
        self.clear = clear
        self.sink = sink
        self.cue = cue
        self.lastMode = settings.value(SettingKeys.captureMode)
    }

    // MARK: Entry points

    /// Launch (FR-002-02, FR-002-08): starts pickup when the setting is on. The existing watermark is kept, so
    /// screenshots taken while Flotsam was not running are caught by the reconcile scan.
    public func start() async {
        guard !stopped, !active, settings.value(SettingKeys.screenshotsEnabled) else { return }
        await activate(freshWatermark: false)
    }

    /// Ends this watcher for good: the owner is quitting or replacing it (TASK-510). New work stops at once: the watch is
    /// torn down (an event or scan already on its way is discarded), the poll timer is cancelled, and the watcher never
    /// starts pickup again whatever `start()`, `settingsDidChange()`, a wake or an event says; `importRecent()` fails as
    /// paused, and so does a press already scanning when this runs (it queues nothing once its listing returns). Imports already accepted then run to their end, so their watermark writes land (a quit that dropped them
    /// would have the next launch select those files again), and finally pickup goes off as `deactivate` does (FR-002-05).
    /// When this returns the watcher has nothing running and writes nothing more. Nothing in the app calls it yet, so no
    /// product behaviour changes.
    public func stop() async {
        stopped = true
        cancelTick?()
        cancelTick = nil
        teardown()
        while running > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        await deactivate()
    }

    /// Imports started and not yet fully finished. Internal, for tests that must know a pickup has gone quiet.
    var importsRunning: Int { running }

    private func importEnded() {
        running -= 1
        guard running == 0 else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// One of `screenshots.enabled`, `screenshots.folderOverride` or `capture.mode` changed.
    public func settingsDidChange() async {
        guard !stopped else { return }
        let enabled = settings.value(SettingKeys.screenshotsEnabled)
        if enabled && !active {
            await activate(freshWatermark: true)
        } else if !enabled && active {
            await deactivate()
        } else if active {
            let mode = settings.value(SettingKeys.captureMode)
            if mode != lastMode {
                lastMode = mode
                // FR-002-05: neither entering nor leaving a non-importing mode may import what happened in between.
                if !mode.importsScreenshots { dropQueuedJobs() }
                await advanceWatermark(to: clock.now())
            }
            await evaluate(reconcile: false)
        }
    }

    /// FR-002-02, FR-002-03, FR-002-08.
    public func didBecomeActive() async {
        guard active, !stopped else { return }
        await evaluate(reconcile: true)
    }

    /// FR-002-08: a reconcile scan on wake from sleep.
    public func didWake() async {
        guard active, !stopped else { return }
        await evaluate(reconcile: true)
    }

    /// The one action behind "Import recent screenshots" (FR-002-12), for onboarding's checkbox and Settings' button:
    /// runs `importRecent()` and tells `hud` "Imported {n}" with the real count, including 0 (the user asked, so a
    /// silent result would look like nothing happened). A run that could not happen (folder paused or refused, every
    /// file failed to store) tells `hud` the failure's message instead: "Imported 0" would say the folder was empty.
    ///
    /// A call that arrives while another run is in flight joins it instead of starting a second scan: it waits for
    /// that run and shows nothing itself, so exactly one HUD reports the run's real result and "Imported 0" never
    /// appears for a call that merely overlapped.
    public func importRecentAnnouncing(hud: @escaping @MainActor @Sendable (String) -> Void) async {
        if let running = announcing {
            await running.value
            return
        }
        let run = Task {
            switch await self.importRecent() {
            case .success(let created): await hud(ScreenshotImportHUD.message(count: created))
            case .failure(let error): await hud(FlotsamStrings.message(for: error))
            }
            self.announcementFinished()
        }
        announcing = run
        await run.value
    }

    private func announcementFinished() { announcing = nil }

    /// "Import recent screenshots" (FR-002-12): the qualifying files of the resolved folder regardless of the
    /// watermark, bounded by the retention window and 500 files, oldest first. Succeeds with how many items were
    /// created (0 for an empty folder or files already in the library); fails when the run could not happen: the
    /// override folder is gone (`SSP-IO-003`), the folder cannot be listed (`SSP-PRM-001` when refused for
    /// permission), or every file failed to store (the first storage error). A run where some files stored and some
    /// failed succeeds with the stored count; each failure is reported on its own.
    ///
    /// Available whether or not pickup is on and in every capture mode, because the user asked for it explicitly.
    /// Files go in with `countsAsCopy: false`: an existing item is left exactly as it was (FRD-001 FR-001-15).
    ///
    /// A press that coincides with live pickup (the `didBecomeActive` reconcile queues the same new files) counts what
    /// its own scan finds new to the library: a file live pickup has queued or has in flight joins the press, and one
    /// live pickup imported after the press began counts too; a file live pickup imported before the press began is
    /// already in the library. None is ingested a second time, so each file is ingested once.
    /// A joined live job that capture mode or pickup-off drops from the queue is imported by the press itself.
    public func importRecent() async -> FlotsamResult<Int> {
        guard !stopped else { return .failure(Self.pausedError) }
        // Registered before the first suspension, so a live import that ends while the press scans is noted for it.
        let id = UUID()
        batches[id] = Batch(total: 0, remaining: 0)

        let location = await Self.resolve(resolver, override: settings.value(SettingKeys.screenshotsFolderOverride))
        guard let folder = location.folder else {
            batches[id] = nil
            return .failure(Self.pausedError)
        }
        let files: [ScreenshotFile]
        let scanned = await Self.scan(scanner, folder: folder)
        // `stop()` ran while the listing was out (TASK-517): the press is abandoned before it raises, queues or counts
        // anything, and resolves as paused so its caller does not hang. `stop()` only waits on imports already started.
        if stopped { return abandonPress(id) }
        switch scanned {
        case .success(let listed): files = listed
        case .failure(let error):
            batches[id] = nil
            guard ScreenshotFolderAccess.isPermissionDenied(error) else { return .failure(error) }
            await raiseAccessDenied()
            return .failure(Self.accessDeniedError)
        }
        let chosen = ScreenshotSelection.backfill(
            files, now: clock.now(), retention: settings.value(SettingKeys.storageRetention))
        var own: [ScreenshotFile] = []
        for file in chosen {
            let path = file.url.path
            // A live import that ended during the scan is counted whether or not the path is pending again: the same
            // path can be imported live twice inside one scan window, and each import counts.
            var counted = false
            if let outcomes = batches[id]?.liveImports[path] {
                counted = true
                batches[id]?.total += outcomes.count
                batches[id]?.created += outcomes.filter { $0 }.count
            }
            if pending.contains(path) {
                joiners[path, default: []].append(id)
                batches[id]?.total += 1
                batches[id]?.remaining += 1
            } else if !counted && !ingestedLive.contains(file) {
                own.append(file)
            }
        }
        batches[id]?.total += own.count
        batches[id]?.remaining += own.count
        // The press read the folder, so a refusal an earlier press raised while pickup was off has ended. Live pickup
        // clears its own refusal when its scan next succeeds (`reconcileScan`), and its watch is stopped until then.
        if !active { await markAccessGranted() }
        // The clear above suspends, so `stop()` can land here too (TASK-517). Nothing suspends between this check and
        // `enqueue`, so a press that passes it is an import accepted before `stop()`, which `stop()` then waits for.
        if stopped { return abandonPress(id) }
        guard let batch = batches[id] else { return .success(0) }
        if batch.remaining == 0 {
            batches[id] = nil
            return batch.result
        }
        return await withCheckedContinuation { continuation in
            batches[id]?.continuation = continuation
            enqueue(own, batch: id, bypassSeen: true)
        }
    }

    /// A press that `stop()` overtook: its batch is dropped (a job that joined stays accepted and ends on its own, and
    /// `record` skips the missing batch) and it fails as paused, as a press made after `stop()` does.
    private func abandonPress(_ id: UUID) -> FlotsamResult<Int> {
        batches[id] = nil
        return .failure(Self.pausedError)
    }

    // MARK: Activation

    private func activate(freshWatermark: Bool) async {
        guard !stopped else { return }
        active = true
        lastMode = settings.value(SettingKeys.captureMode)
        let mine = session
        if freshWatermark {
            await advanceWatermark(to: clock.now())
            // The write suspends: pickup may have been turned off (and on again) meanwhile. Registering the timer now
            // would leave one running after off (FR-002-05), or a second one beside the new activation's. `session`,
            // not `generation`: a re-resolution that rebuilds the watch is not an overtaker of the activation.
            guard active, session == mine else { return }
        }
        cancelTick = pollTick.every(Self.tickInterval) { [weak self] in Task { await self?.tickFired() } }
        await evaluate(reconcile: true)
    }

    /// FR-002-05: no watcher, no timer, no folder access, and none of the conditions it raised left standing.
    private func deactivate() async {
        active = false
        session += 1
        cancelTick?()
        cancelTick = nil
        teardown()
        dropQueuedJobs()
        retry.removeAll()
        unfinished.removeAll()
        hiddenFiles.removeAll()
        location = nil
        let ended = [raisedLocationWarning, accessDenied ? ErrorCode.sspPrm001 : nil, inFallback ? ErrorCode.sspOs001 : nil]
        raisedLocationWarning = nil
        accessDenied = false
        inFallback = false
        status = .off
        // Each clear suspends, so an activation can run between two of them and raise a condition of its own. A clear
        // of the same code would then wipe the new notice while the flags say it stands (and nothing raises it again).
        // The reporter applies a clear when the call starts, so the check before each one is what orders them.
        for code in ended.compactMap({ $0 }) where !isRaised(code) { await clear(code) }
    }

    /// Whether the watcher currently holds `code` as one of its raised conditions.
    private func isRaised(_ code: ErrorCode) -> Bool {
        switch code {
        case .sspPrm001: accessDenied
        case .sspOs001: inFallback
        default: raisedLocationWarning == code
        }
    }

    /// The 30 s work, run from the shared poll tick (`PollTick`). Internal so tests can run one tick to completion.
    /// Ticks never overlap: the work suspends (listing, the folder-access prompt, the watermark write), so a tick that
    /// fires while the previous one is unfinished is dropped; the next tick does the work.
    func tickFired() async {
        guard active, !stopped, !tickRunning else { return }
        tickRunning = true
        defer { tickRunning = false }
        await evaluate(reconcile: false)
        if inFallback { await tryLeaveFallback() }
        await retryUnstable()
        // FR-002-08: the folder was listed and is being watched, so what the watermark covers is known up to now.
        // Not while access is refused or no folder is watched: a file that could not be seen must stay inside it.
        if active, !accessDenied, location?.folder != nil {
            await advanceWatermark(to: heldWatermark(clock.now()), scan: false)
        }
    }

    // MARK: Location

    /// Re-resolves the location. A different folder, or a folder that could not be listed last time, is rebuilt;
    /// otherwise the watch stays and `reconcile` decides whether to scan anyway.
    private func evaluate(reconcile: Bool) async {
        guard active else { return }
        let generationBefore = generation
        let resolved = await Self.resolve(resolver, override: settings.value(SettingKeys.screenshotsFolderOverride))
        guard active, generation == generationBefore else { return }
        if resolved == location && !accessDenied {
            if reconcile { await reconcileScan() }
            return
        }
        await rebuild(for: resolved)
    }

    /// Every suspension below lets the actor serve other calls: pickup turned off (`deactivate`) or a second
    /// re-resolution (which tears down and rebuilds again). Both bump `generation`, so a rebuild that finds it changed,
    /// or pickup off, after a suspension was overtaken and stops: what it would install is no longer wanted, and the
    /// overtaker owns the location, the status and the watch.
    private func rebuild(for resolved: ScreenshotLocation) async {
        teardown()
        // The watch is gone, so the old location is no longer what is installed. Until this rebuild installs
        // `resolved` (after the suspensions below), a re-resolution that returns to the old location must rebuild too:
        // `evaluate` would skip it as unchanged, and this stale rebuild would then win over the settings that ended up.
        location = nil
        let mine = generation
        await updateLocationWarning(for: resolved)
        guard active, generation == mine else { return }
        location = resolved
        guard let folder = resolved.folder else {
            // Nothing is watched, so a refusal or a polling fallback raised for the previous folder no longer stands.
            await leaveFallbackState()
            await markAccessGranted()
            guard active, generation == mine else { return }
            status = .paused
            await seedWatermarkIfNone(at: clock.now())
            return
        }
        status = resolved == .watching(folder) ? .watching : .usingDesktop
        await startWatch(on: folder)
        // Raising or clearing the polling notice suspends, like every other await here.
        guard active, generation == mine else { return }
        await reconcileScan()
    }

    /// FR-002-01: `SSP-IO-001` / `SSP-IO-003` are raised once per change of state and cleared when it ends.
    private func updateLocationWarning(for resolved: ScreenshotLocation) async {
        let wanted = resolved.warning
        guard wanted != raisedLocationWarning else { return }
        let previous = raisedLocationWarning
        let mine = session
        raisedLocationWarning = wanted
        if let previous {
            await clear(previous)
            // The clear suspends. Pickup off ends the session and has cleared `wanted` itself (FR-002-05), so raising
            // it now would leave it standing. A later re-resolution may have claimed or released it meanwhile
            // (`raisedLocationWarning` no longer `wanted`): then it owns the notice. Not `generation`: a rebuild
            // that found `wanted` already claimed raised nothing, so this call is still the one that must.
            guard active, session == mine, raisedLocationWarning == wanted else { return }
        }
        switch wanted {
        case .sspIo001?: await report(FlotsamError(.sspIo001, "System screenshot location unusable, watching Desktop"))
        case .sspIo003?: await report(Self.pausedError)
        default: break
        }
    }

    // MARK: Watching

    private func teardown() {
        watch?.stop()
        watch = nil
        generation += 1
    }

    /// The watch is installed before the first suspension (the notice calls), so an overtaker's `teardown` stops it.
    private func startWatch(on folder: URL) async {
        let current = generation
        let handler: @Sendable (FolderEvent) -> Void = { [weak self] event in
            guard let self else { return }
            Task { await self.handle(event, generation: current) }
        }
        switch eventSource.start(watching: folder, handler: handler) {
        case .success(let started):
            watch = started
            await leaveFallbackState()
        case .failure:
            await startPolling(folder, handler: handler)
        }
    }

    /// FR-002-04: the stream could not be created or went invalid; list the folder every 5 s instead. Installs the
    /// polling watch (nil when even that cannot start) and raises `SSP-OS-001` once.
    ///
    /// The notice is awaited in the caller's own flow, never from an unstructured `Task` (TASK-483): such a task is
    /// queued behind whatever is already waiting for the actor, so a `deactivate` already in line ran first, cleared
    /// the notice, and then the task raised it again after pickup was off (FR-002-05).
    private func startPolling(_ folder: URL, handler: @escaping @Sendable (FolderEvent) -> Void) async {
        guard case .success(let started) = fallbackSource.start(watching: folder, handler: handler) else {
            watch = nil
            return
        }
        watch = started
        if !inFallback {
            inFallback = true
            await report(FlotsamError(.sspOs001, "Folder events unavailable, polling every 5 seconds"))
        }
    }

    /// Awaited for the same reason as `startPolling`'s notice: the clear stays ordered with the raise before it.
    private func leaveFallbackState() async {
        guard inFallback else { return }
        inFallback = false
        await clear(.sspOs001)
    }

    /// FR-002-04: "leaving the fallback (stream creation succeeds on a later re-resolution) clears it". The 30 s tick is
    /// the later re-resolution when the folder itself has not changed.
    private func tryLeaveFallback() async {
        guard active, inFallback, let folder = location?.folder, !accessDenied else { return }
        let current = generation
        let handler: @Sendable (FolderEvent) -> Void = { [weak self] event in
            guard let self else { return }
            Task { await self.handle(event, generation: current) }
        }
        guard case .success(let started) = eventSource.start(watching: folder, handler: handler) else { return }
        watch?.stop()
        watch = started
        await leaveFallbackState()
        // The clear suspends: an overtaker (`deactivate`, a rebuild) owns the watch and the scan now.
        guard active, generation == current else { return }
        // Whatever arrived while only the poll was looking is already covered; the gap to the stream is not.
        await reconcileScan()
    }

    private func handle(_ event: FolderEvent, generation eventGeneration: Int) async {
        guard active, eventGeneration == generation else { return }
        switch event {
        case .changed(let urls): await ingestEvents(urls)
        case .rescan: await reconcileScan()
        case .invalidated:
            guard let folder = location?.folder else { return }
            watch?.stop()
            let current = generation
            await startPolling(folder) { [weak self] event in
                guard let self else { return }
                Task { await self.handle(event, generation: current) }
            }
        }
    }

    // MARK: Selecting files

    private func ingestEvents(_ urls: [URL]) async {
        guard settings.value(SettingKeys.captureMode).importsScreenshots, let folder = location?.folder else { return }
        let current = generation
        let files = await Self.directChildren(of: folder, among: urls, scanner: scanner)
        let hidden = await Self.hiddenChildren(of: folder, among: urls, scanner: scanner)
        guard active, generation == current else { return }
        for (path, birth) in hidden { hiddenFiles[path] = birth }
        // No watermark yet: a new library imports nothing (FR-002-08).
        guard !files.isEmpty else { return }
        let known = await currentWatermark()
        // The watermark load suspends: pickup may have been turned off, or the watch replaced, meanwhile (FR-002-05).
        guard active, generation == current, known != nil, let floor = eventFloor else { return }
        enqueue(ScreenshotSelection.reconcile(files, lastScanAt: floor), batch: nil, bypassSeen: false)
    }

    /// FR-002-08. Also the access probe (FR-002-03): a listing refused for permission lands in `markAccessDenied`.
    private func reconcileScan() async {
        guard active, let folder = location?.folder else { return }
        let current = generation
        let started = clock.now()
        let result = await Self.list(scanner, folder: folder)
        guard active, generation == current else { return }
        let files: [ScreenshotFile]
        switch result {
        case .failure(let error):
            if ScreenshotFolderAccess.isPermissionDenied(error) { await markAccessDenied(at: started) }
            FlotsamLog.log(.screenshotScanned(outcome: .failed, count: 0), sink: sink)
            return
        case .success(let listing):
            files = listing.files
            hiddenFiles = listing.hiddenFiles
        }
        await markAccessGranted()
        // `markAccessGranted` and the watermark loads below suspend, and pickup can be turned off (FR-002-05) or the
        // watch replaced in each gap: an overtaken scan leaves the queue, the watermark and the status to its overtaker.
        guard active, generation == current else { return }

        guard settings.value(SettingKeys.captureMode).importsScreenshots else {
            await advanceWatermark(to: started)
            FlotsamLog.log(.screenshotScanned(outcome: .succeeded, count: 0), sink: sink)
            return
        }
        var queued = 0
        // No watermark yet: a new library imports nothing and only records where it is (FR-002-08).
        let last = await currentWatermark()
        guard active, generation == current else { return }
        if let last {
            let present = Set(files.map(\.url.path))
            retry = retry.filter { present.contains($0.key) }
            unfinished = unfinished.filter { present.contains($0.key) }
            // The retry is spent before the selection is queued: a file the watermark window also selects would
            // otherwise be queued first and found `pending`, and never use up its budget (FR-002-07).
            let selected = retryDue(among: files) + ScreenshotSelection.reconcile(files, lastScanAt: last)
            queued = Set(selected.map(\.url.path)).count
            enqueue(selected, batch: nil, bypassSeen: false)
        }
        await advanceWatermark(to: heldWatermark(started))
        FlotsamLog.log(.screenshotScanned(outcome: .succeeded, count: queued), sink: sink)
    }

    /// FR-002-03: pickup stays idle and the next tick or activation lists the folder again.
    private func markAccessDenied(at scanStart: Date) async {
        let mine = generation
        watch?.stop()
        watch = nil
        status = .needsAccess
        await seedWatermarkIfNone(at: scanStart)
        // The seed suspends: pickup off (FR-002-05: no condition outlives it) or a rebuild may have overtaken this
        // refusal, and either one owns the status and the notice now.
        guard active, generation == mine else { return }
        await raiseAccessDenied()
    }

    /// The one place `SSP-PRM-001` is raised, so the flag and the notice cannot part: `deactivate` and `markAccessGranted`
    /// clear the notice by the flag. A press (`importRecent`) that finds the folder refused comes through here too.
    private func raiseAccessDenied() async {
        guard !accessDenied else { return }
        accessDenied = true
        await report(Self.accessDeniedError)
    }

    private func markAccessGranted() async {
        guard accessDenied else { return }
        accessDenied = false
        status = location.map(statusFor) ?? .off
        await clear(.sspPrm001)
    }

    private func statusFor(_ location: ScreenshotLocation) -> ScreenshotPickupStatus {
        switch location {
        case .watching: .watching
        case .usingDesktop: .usingDesktop
        case .paused: .paused
        }
    }

    private static var pausedError: FlotsamError {
        FlotsamError(.sspIo003, "Chosen screenshot folder unusable, pickup paused")
    }

    private static var accessDeniedError: FlotsamError {
        FlotsamError(.sspPrm001, "Screenshot folder access was refused")
    }

    // MARK: Watermark

    private func currentWatermark() async -> Date? {
        if !watermarkLoaded {
            let mine = session
            switch await watermarkStore.lastScanAt() {
            case .success(let date):
                watermark = date
                watermarkLoaded = true
                if eventFloor == nil { eventFloor = date }
            case .failure(let error):
                await reportWhileLive(error, since: mine)
                return nil
            }
        }
        return watermark
    }

    /// Never moves backwards, so two scans finishing out of order cannot re-open a window already scanned. A scan
    /// (`scan`, the default) also moves the floor live file events are judged by; an import or the tick does not.
    private func advanceWatermark(to date: Date, scan: Bool = true) async {
        let mine = session
        let known = await currentWatermark()
        if scan { eventFloor = max(eventFloor ?? date, date) }
        if let known, known >= date { return }
        watermark = date
        watermarkLoaded = true
        if case .failure(let error) = await watermarkStore.setLastScanAt(date) { await reportWhileLive(error, since: mine) }
    }

    /// FR-002-05: a report that follows a suspension is raised only if the pickup session it began in is still the
    /// live one. Pickup turned off (or off and on again) while it waited makes it a condition of a session nobody has.
    private func reportWhileLive(_ error: FlotsamError, since session: Int) async {
        guard active, self.session == session else { return }
        await report(error)
    }

    /// FR-002-08: `proposed`, but not past the birth of a file that is not finished: still hidden, queued, unstable
    /// or failed. Its birth date has to stay inside the window the next scan selects by.
    private func heldWatermark(_ proposed: Date, importedBirth: Date? = nil) -> Date {
        let now = clock.now()
        unfinished = unfinished.filter { ScreenshotSelection.isHeld($0.value, now: now) }
        hiddenFiles = hiddenFiles.filter { ScreenshotSelection.isHeld($0.value, now: now) }
        return ScreenshotSelection.heldBack(
            proposed, now: now, births: Array(unfinished.values) + Array(hiddenFiles.values), importedBirth: importedBirth)
    }

    private func seedWatermarkIfNone(at date: Date) async {
        if await currentWatermark() == nil, watermarkLoaded { await advanceWatermark(to: date) }
    }

    // MARK: Importing

    /// FR-002-13: FIFO, at most `maxInFlight` at once. FR-002-12: live pickup (no batch) goes ahead of every queued
    /// backfill job, so a 500-file backfill never starves a fresh screenshot; each class stays FIFO within itself.
    private func enqueue(_ files: [ScreenshotFile], batch: UUID?, bypassSeen: Bool) {
        for file in files {
            let path = file.url.path
            guard !pending.contains(path), bypassSeen || !seen.contains(file) else { continue }
            pending.insert(path)
            if batch == nil { unfinished[path] = file.createdAt }
            let job = ImportJob(file: file, batch: batch, session: session)
            if batch == nil, let firstBackfill = queue.firstIndex(where: { $0.batch != nil }) {
                queue.insert(job, at: firstBackfill)
            } else {
                queue.append(job)
            }
        }
        pump()
    }

    private func pump() {
        while inFlight < Self.maxInFlight, !queue.isEmpty {
            let job = queue.removeFirst()
            inFlight += 1
            running += 1
            let importer = importer
            Task {
                let attempt = await importer.run(job.file, countsAsCopy: job.batch == nil)
                await self.finish(job, attempt)
            }
        }
    }

    private func finish(_ job: ImportJob, _ attempt: ScreenshotImportAttempt) async {
        inFlight -= 1
        let path = job.file.url.path
        pending.remove(path)
        // Taken now, not after the awaits below: a press landing in between must not be mistaken for a joiner, and
        // a later job for the same path must not resolve these.
        let joined = joiners.removeValue(forKey: path) ?? []
        var created = false
        var failure: FlotsamError?
        switch attempt {
        case .imported(let result, let byteSize):
            if case .created = result.outcome { created = true }
            seen.insert(job.file)
            if job.batch == nil {
                ingestedLive.insert(job.file)
                noteLiveImport(path, created: created)
            }
            retry[job.file.url.path] = nil
            await settle(job)
            FlotsamLog.log(.screenshotImported(outcome: created ? .stored : .deduped, byteSize: byteSize), sink: sink)
            // FR-001-30: a newly stored screenshot picked up live. Not "Import recent screenshots" (it ends in its own
            // "Imported {n}" HUD, FR-002-12), and not one from a pickup session that has ended.
            if created, job.batch == nil, active, job.session == session { cue?.captured(.screenshot) }
            for warning in result.warnings where mayReport(for: job) { await report(warning) }
        case .unstable(let error):
            // `deactivate` emptied the retry list (FR-002-05): an import that was already running when pickup went off
            // and ends unstable must not put its file back, or a later reactivation would retry a file from before the
            // off period. A file still unstable in the same session stays on the list.
            if job.batch == nil, job.session == session { noteUnstable(job.file) }
            if mayReport(for: job) { await report(error) }
        case .rejected(let error, let byteSize):
            seen.insert(job.file)
            retry[job.file.url.path] = nil
            await settle(job)
            FlotsamLog.log(.screenshotImported(outcome: .skipped, byteSize: byteSize), sink: sink)
            if mayReport(for: job) { await report(error) }
        case .failed(let error, let byteSize):
            failure = error
            FlotsamLog.log(.screenshotImported(outcome: .failed, byteSize: byteSize), sink: sink)
            if mayReport(for: job) { await report(error) }
        }
        complete(job, joined: joined, created: created, failure: failure)
        pump()
        importEnded()
    }

    /// FR-002-05: a live job of a session that has ended reports nothing, whatever its outcome: the notice would stand
    /// for a file nobody is watching. Checked at the point of each report, after the awaits before it. A press's job
    /// is the user's own request (FR-002-12), so its notices stand in any session.
    private func mayReport(for job: ImportJob) -> Bool {
        job.batch != nil || (active && job.session == session)
    }

    /// A live import that ends while a press is still scanning is the press's to count when its scan lists the file:
    /// by then the file is neither pending nor new to the library. Only presses still scanning (no continuation yet)
    /// are noted; a press that joined this job is already waiting, so it counts the job through `complete` instead.
    /// Every import of a path is kept, so the same path imported twice during one scan counts twice.
    private func noteLiveImport(_ path: String, created: Bool) {
        for (id, batch) in batches where batch.continuation == nil {
            batches[id]?.liveImports[path, default: []].append(created)
        }
    }

    /// FR-002-08: a live file that is done (imported, or recognised as not importable) no longer holds the watermark,
    /// and the watermark moves past it, so a relaunch does not select it again, whether or not the user has deleted
    /// the item since. The seen set cannot do this: it lives in memory only.
    private func settle(_ job: ImportJob) async {
        guard job.batch == nil else { return }
        unfinished[job.file.url.path] = nil
        guard active else { return }
        let proposed = ScreenshotSelection.watermarkAfterImport(of: job.file, now: clock.now())
        await advanceWatermark(to: heldWatermark(proposed, importedBirth: job.file.createdAt), scan: false)
    }

    /// A job's end counts toward its own press (a backfill job) and every press that joined it (a live job).
    private func complete(_ job: ImportJob, joined: [UUID], created: Bool, failure: FlotsamError?) {
        var presses = joined
        if let id = job.batch, !presses.contains(id) { presses.append(id) }
        for id in presses { record(id, created: created, failure: failure) }
    }

    private func record(_ id: UUID, created: Bool, failure: FlotsamError?) {
        guard var batch = batches[id] else { return }
        batch.remaining -= 1
        if created { batch.created += 1 }
        if let failure {
            batch.failed += 1
            batch.firstFailure = batch.firstFailure ?? failure
        }
        // Until the press has finished looking at the folder it is not waiting yet (`continuation` is nil).
        if batch.remaining == 0, let continuation = batch.continuation {
            batches[id] = nil
            continuation.resume(returning: batch.result)
        } else {
            batches[id] = batch
        }
    }

    /// The queue is emptied when the capture mode stops importing or pickup is turned off (FR-002-05).
    /// Backfill jobs are the user's explicit request and stay. A live job a press joined is the press's request too
    /// (FR-002-12: neither gate applies to it), so it is not dropped but handed to the first press that joined it as
    /// its own backfill job; any other press that joined it keeps waiting on that job.
    private func dropQueuedJobs() {
        let dropped = queue.filter { $0.batch == nil }
        queue.removeAll { $0.batch == nil }
        for job in dropped {
            let path = job.file.url.path
            unfinished[path] = nil
            let presses = (joiners.removeValue(forKey: path) ?? []).filter { batches[$0] != nil }
            guard let owner = presses.first else {
                pending.remove(path)
                continue
            }
            if presses.count > 1 { joiners[path] = Array(presses.dropFirst()) }
            queue.append(ImportJob(file: job.file, batch: owner, session: session))
        }
        pump()
    }

    // MARK: Retry list (FR-002-07)

    private func noteUnstable(_ file: ScreenshotFile) {
        let path = file.url.path
        if let entry = retry[path], entry.retriesLeft == 0 {
            // Out of retries: dropped. Marked seen so the watermark window cannot select it again; only
            // "Import recent screenshots" (which bypasses `seen`) can still bring it in.
            retry[path] = nil
            unfinished[path] = nil
            seen.insert(file)
        } else if retry[path] == nil {
            retry[path] = RetryEntry(file: file, retriesLeft: Self.maxRetries)
        }
    }

    /// The files on the retry list that a scan found again, each one retry spent.
    private func retryDue(among files: [ScreenshotFile]) -> [ScreenshotFile] {
        files.compactMap { file in
            let path = file.url.path
            guard var entry = retry[path], entry.retriesLeft > 0, !pending.contains(path) else { return nil }
            entry.retriesLeft -= 1
            retry[path] = entry
            return file
        }
    }

    /// A file that stayed unstable may settle without producing another event, so the tick looks at the list too.
    private func retryUnstable() async {
        guard settings.value(SettingKeys.captureMode).importsScreenshots, !retry.isEmpty, let folder = location?.folder else { return }
        let current = generation
        let urls = retry.values.map(\.file.url)
        let files = await Self.directChildren(of: folder, among: urls, scanner: scanner)
        guard active, generation == current else { return }
        let present = Set(files.map(\.url.path))
        retry = retry.filter { present.contains($0.key) }
        enqueue(retryDue(among: files), batch: nil, bypassSeen: false)
    }

    // MARK: Off-actor file system work

    @concurrent
    private static func resolve(_ resolver: ScreenshotLocationResolver, override: FolderOverride) async -> ScreenshotLocation {
        resolver.resolve(override: override.resolvedURL)
    }

    @concurrent
    private static func list(_ scanner: ScreenshotFolderScanner, folder: URL) async -> FlotsamResult<ScreenshotListing> {
        scanner.listing(folder)
    }

    @concurrent
    private static func scan(_ scanner: ScreenshotFolderScanner, folder: URL) async -> FlotsamResult<[ScreenshotFile]> {
        scanner.scan(folder)
    }

    /// FR-002-08: the hidden direct children an event batch names, with their birth dates; nil for one that is gone
    /// or no longer hidden (the rename that ends a screenshot's save reports the temporary name as well).
    @concurrent
    private static func hiddenChildren(of folder: URL, among urls: [URL], scanner: ScreenshotFolderScanner) async -> [(String, Date?)] {
        urls.compactMap { url in
            let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            guard parent.path == folder.path, ScreenshotRecognizer.isHiddenName(url.lastPathComponent) else { return nil }
            let child = folder.appendingPathComponent(url.lastPathComponent)
            return (child.path, scanner.hiddenBirth(child))
        }
    }

    /// FR-002-04: FSEvents is file-level and non-recursive in effect only by this filter. A path whose parent is not
    /// the watched folder (a descendant) is dropped, and the file is re-read from the folder so a symbolic link
    /// the stream resolved differently cannot slip a different path in.
    @concurrent
    private static func directChildren(of folder: URL, among urls: [URL], scanner: ScreenshotFolderScanner) async -> [ScreenshotFile] {
        var visited = Set<String>()
        return urls.compactMap { url in
            let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            guard parent.path == folder.path else { return nil }
            let child = folder.appendingPathComponent(url.lastPathComponent)
            guard visited.insert(child.path).inserted else { return nil }
            return scanner.candidate(child, in: folder)
        }
    }
}

// MARK: - Value types

private struct ImportJob: Sendable {
    let file: ScreenshotFile
    /// Set for "Import recent screenshots", whose caller waits for the count.
    let batch: UUID?
    /// The `ScreenshotWatcher.session` the job was queued in.
    let session: Int
}

private struct RetryEntry: Sendable {
    let file: ScreenshotFile
    var retriesLeft: Int
}

private struct Batch {
    var total: Int
    var remaining: Int
    var created = 0
    var failed = 0
    var firstFailure: FlotsamError?
    /// Live imports that ended while the press scanned: per path, one entry per import, true when it created an item.
    var liveImports: [String: [Bool]] = [:]
    /// Set once the press has chosen its files and waits for the last one.
    var continuation: CheckedContinuation<FlotsamResult<Int>, Never>?

    /// Every file failing to store is a failed run; any file that stored (or was already in the library) makes it a
    /// run with a count.
    var result: FlotsamResult<Int> {
        if failed == total, let firstFailure { return .failure(firstFailure) }
        return .success(created)
    }
}

/// Remembers which files were imported (or can never be) so the same file is not imported twice by repeated events,
/// the 5 s watermark slack or two scans in a row. Keyed by path and birth date: a file replaced under the same name
/// has a new birth date and imports again, one merely re-saved in place does not. Bounded so a long session over a
/// busy folder cannot grow it without limit; forgetting an old entry is safe, ingest dedupes by content anyway.
struct SeenFiles {
    private let capacity: Int
    private var dates: [String: Date] = [:]
    private var order: [String] = []

    init(capacity: Int) { self.capacity = capacity }

    func contains(_ file: ScreenshotFile) -> Bool { dates[file.url.path] == file.createdAt }

    mutating func insert(_ file: ScreenshotFile) {
        let path = file.url.path
        if dates.updateValue(file.createdAt, forKey: path) == nil { order.append(path) }
        if order.count > capacity { dates[order.removeFirst()] = nil }
    }
}
