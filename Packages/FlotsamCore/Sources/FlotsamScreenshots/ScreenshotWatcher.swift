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

    // MARK: State

    public private(set) var status: ScreenshotPickupStatus = .off
    private var active = false
    private var location: ScreenshotLocation?
    private var lastMode: CaptureMode
    /// Bumped on every teardown; events and scan results from an earlier watch are discarded.
    private var generation = 0
    private var watch: (any FolderWatch)?
    private var cancelTick: (@Sendable () -> Void)?

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
    private var batches: [UUID: Batch] = [:]

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
        self.lastMode = settings.value(SettingKeys.captureMode)
    }

    // MARK: Entry points

    /// Launch (FR-002-02, FR-002-08): starts pickup when the setting is on. The existing watermark is kept, so
    /// screenshots taken while Flotsam was not running are caught by the reconcile scan.
    public func start() async {
        guard !active, settings.value(SettingKeys.screenshotsEnabled) else { return }
        await activate(freshWatermark: false)
    }

    /// One of `screenshots.enabled`, `screenshots.folderOverride` or `capture.mode` changed.
    public func settingsDidChange() async {
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
        guard active else { return }
        await evaluate(reconcile: true)
    }

    /// FR-002-08: a reconcile scan on wake from sleep.
    public func didWake() async {
        guard active else { return }
        await evaluate(reconcile: true)
    }

    /// "Import recent screenshots" (FR-002-12): the qualifying files of the resolved folder regardless of the
    /// watermark, bounded by the retention window and 500 files, oldest first. Returns how many items were created.
    ///
    /// Available whether or not pickup is on and in every capture mode, because the user asked for it explicitly.
    /// Files go in with `countsAsCopy: false`: an existing item is left exactly as it was (FRD-001 FR-001-15).
    public func importRecent() async -> Int {
        let location = await Self.resolve(resolver, override: settings.value(SettingKeys.screenshotsFolderOverride))
        guard let folder = location.folder else { return 0 }
        let files: [ScreenshotFile]
        switch await Self.scan(scanner, folder: folder) {
        case .success(let listed): files = listed
        case .failure(let error):
            if ScreenshotFolderAccess.isPermissionDenied(error) { await report(Self.accessDeniedError) }
            return 0
        }
        let chosen = ScreenshotSelection.backfill(
            files, now: clock.now(), retention: settings.value(SettingKeys.storageRetention))
        let jobs = chosen.filter { !pending.contains($0.url.path) }
        guard !jobs.isEmpty else { return 0 }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            batches[id] = Batch(remaining: jobs.count, created: 0, continuation: continuation)
            enqueue(jobs, batch: id, bypassSeen: true)
        }
    }

    // MARK: Activation

    private func activate(freshWatermark: Bool) async {
        active = true
        lastMode = settings.value(SettingKeys.captureMode)
        if freshWatermark { await advanceWatermark(to: clock.now()) }
        cancelTick = pollTick.every(Self.tickInterval) { Task { await self.tickFired() } }
        await evaluate(reconcile: true)
    }

    /// FR-002-05: no watcher, no timer, no folder access, and none of the conditions it raised left standing.
    private func deactivate() async {
        active = false
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
        for code in ended.compactMap({ $0 }) { await clear(code) }
    }

    /// The 30 s work, run from the shared poll tick (`PollTick`). Internal so tests can run one tick to completion.
    func tickFired() async {
        guard active else { return }
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

    private func rebuild(for resolved: ScreenshotLocation) async {
        teardown()
        await updateLocationWarning(for: resolved)
        location = resolved
        guard let folder = resolved.folder else {
            // Nothing is watched, so a refusal or a polling fallback raised for the previous folder no longer stands.
            leaveFallbackState()
            await markAccessGranted()
            status = .paused
            await seedWatermarkIfNone(at: clock.now())
            return
        }
        status = resolved == .watching(folder) ? .watching : .usingDesktop
        startWatch(on: folder)
        await reconcileScan()
    }

    /// FR-002-01: `SSP-IO-001` / `SSP-IO-003` are raised once per change of state and cleared when it ends.
    private func updateLocationWarning(for resolved: ScreenshotLocation) async {
        let wanted = resolved.warning
        guard wanted != raisedLocationWarning else { return }
        let previous = raisedLocationWarning
        raisedLocationWarning = wanted
        if let previous { await clear(previous) }
        switch wanted {
        case .sspIo001?: await report(FlotsamError(.sspIo001, "System screenshot location unusable, watching Desktop"))
        case .sspIo003?: await report(FlotsamError(.sspIo003, "Chosen screenshot folder unusable, pickup paused"))
        default: break
        }
    }

    // MARK: Watching

    private func teardown() {
        watch?.stop()
        watch = nil
        generation += 1
    }

    private func startWatch(on folder: URL) {
        let current = generation
        let handler: @Sendable (FolderEvent) -> Void = { [weak self] event in
            guard let self else { return }
            Task { await self.handle(event, generation: current) }
        }
        switch eventSource.start(watching: folder, handler: handler) {
        case .success(let started):
            watch = started
            leaveFallbackState()
        case .failure:
            watch = startPolling(folder, handler: handler)
        }
    }

    /// FR-002-04: the stream could not be created or went invalid; list the folder every 5 s instead.
    private func startPolling(_ folder: URL, handler: @escaping @Sendable (FolderEvent) -> Void) -> (any FolderWatch)? {
        guard case .success(let started) = fallbackSource.start(watching: folder, handler: handler) else { return nil }
        if !inFallback {
            inFallback = true
            Task { await self.report(FlotsamError(.sspOs001, "Folder events unavailable, polling every 5 seconds")) }
        }
        return started
    }

    private func leaveFallbackState() {
        guard inFallback else { return }
        inFallback = false
        Task { await self.clear(.sspOs001) }
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
        leaveFallbackState()
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
            watch = startPolling(folder) { [weak self] event in
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
        guard !files.isEmpty, await currentWatermark() != nil, let floor = eventFloor else { return }
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

        guard settings.value(SettingKeys.captureMode).importsScreenshots else {
            await advanceWatermark(to: started)
            FlotsamLog.log(.screenshotScanned(outcome: .succeeded, count: 0), sink: sink)
            return
        }
        var queued = 0
        // No watermark yet: a new library imports nothing and only records where it is (FR-002-08).
        if let last = await currentWatermark() {
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
        watch?.stop()
        watch = nil
        status = .needsAccess
        await seedWatermarkIfNone(at: scanStart)
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

    private static var accessDeniedError: FlotsamError {
        FlotsamError(.sspPrm001, "Screenshot folder access was refused")
    }

    // MARK: Watermark

    private func currentWatermark() async -> Date? {
        if !watermarkLoaded {
            switch await watermarkStore.lastScanAt() {
            case .success(let date):
                watermark = date
                watermarkLoaded = true
                if eventFloor == nil { eventFloor = date }
            case .failure(let error):
                await report(error)
                return nil
            }
        }
        return watermark
    }

    /// Never moves backwards, so two scans finishing out of order cannot re-open a window already scanned. A scan
    /// (`scan`, the default) also moves the floor live file events are judged by; an import or the tick does not.
    private func advanceWatermark(to date: Date, scan: Bool = true) async {
        let known = await currentWatermark()
        if scan { eventFloor = max(eventFloor ?? date, date) }
        if let known, known >= date { return }
        watermark = date
        watermarkLoaded = true
        if case .failure(let error) = await watermarkStore.setLastScanAt(date) { await report(error) }
    }

    /// FR-002-08: `proposed`, but not past the birth of a file that is not finished: still hidden, queued, unstable
    /// or failed. Its birth date has to stay inside the window the next scan selects by.
    private func heldWatermark(_ proposed: Date) -> Date {
        let now = clock.now()
        unfinished = unfinished.filter { ScreenshotSelection.isHeld($0.value, now: now) }
        hiddenFiles = hiddenFiles.filter { ScreenshotSelection.isHeld($0.value, now: now) }
        return ScreenshotSelection.heldBack(
            proposed, now: now, births: Array(unfinished.values) + Array(hiddenFiles.values))
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
            let job = ImportJob(file: file, batch: batch)
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
            let importer = importer
            Task {
                let attempt = await importer.run(job.file, countsAsCopy: job.batch == nil)
                await self.finish(job, attempt)
            }
        }
    }

    private func finish(_ job: ImportJob, _ attempt: ScreenshotImportAttempt) async {
        inFlight -= 1
        pending.remove(job.file.url.path)
        var created = false
        switch attempt {
        case .imported(let result, let byteSize):
            seen.insert(job.file)
            retry[job.file.url.path] = nil
            await settle(job)
            if case .created = result.outcome { created = true }
            FlotsamLog.log(.screenshotImported(outcome: created ? .stored : .deduped, byteSize: byteSize), sink: sink)
            for warning in result.warnings { await report(warning) }
        case .unstable(let error):
            if job.batch == nil { noteUnstable(job.file) }
            await report(error)
        case .rejected(let error, let byteSize):
            seen.insert(job.file)
            retry[job.file.url.path] = nil
            await settle(job)
            FlotsamLog.log(.screenshotImported(outcome: .skipped, byteSize: byteSize), sink: sink)
            await report(error)
        case .failed(let error, let byteSize):
            FlotsamLog.log(.screenshotImported(outcome: .failed, byteSize: byteSize), sink: sink)
            await report(error)
        }
        complete(job, created: created)
        pump()
    }

    /// FR-002-08: a live file that is done (imported, or recognised as not importable) no longer holds the watermark,
    /// and the watermark moves past it, so a relaunch does not select it again, whether or not the user has deleted
    /// the item since. The seen set cannot do this: it lives in memory only.
    private func settle(_ job: ImportJob) async {
        guard job.batch == nil else { return }
        unfinished[job.file.url.path] = nil
        guard active else { return }
        let proposed = ScreenshotSelection.watermarkAfterImport(of: job.file, now: clock.now())
        await advanceWatermark(to: heldWatermark(proposed), scan: false)
    }

    private func complete(_ job: ImportJob, created: Bool) {
        guard let id = job.batch, var batch = batches[id] else { return }
        batch.remaining -= 1
        if created { batch.created += 1 }
        if batch.remaining == 0 {
            batches[id] = nil
            batch.continuation.resume(returning: batch.created)
        } else {
            batches[id] = batch
        }
    }

    /// The queue is emptied when the capture mode stops importing or pickup is turned off (FR-002-05).
    /// Backfill jobs are the user's explicit request and stay.
    private func dropQueuedJobs() {
        let dropped = queue.filter { $0.batch == nil }
        queue.removeAll { $0.batch == nil }
        for job in dropped {
            pending.remove(job.file.url.path)
            unfinished[job.file.url.path] = nil
            complete(job, created: false)
        }
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
}

private struct RetryEntry: Sendable {
    let file: ScreenshotFile
    var retriesLeft: Int
}

private struct Batch {
    var remaining: Int
    var created: Int
    let continuation: CheckedContinuation<Int, Never>
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
