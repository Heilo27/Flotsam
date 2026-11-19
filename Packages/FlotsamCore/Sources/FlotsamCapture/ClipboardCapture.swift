import FlotsamBase
import FlotsamPayload
import FlotsamStorage
import Foundation

/// Watches the general pasteboard and hands what is worth keeping to the ingest pipeline (FRD-001).
///
/// Shape (ADR-0004): the main actor owns everything that must touch `NSPasteboard` or `NSWorkspace` (the poll, the
/// gates, the read) and produces an immutable `CapturedPayload`. A single off-main consumer task classifies, hashes
/// and ingests it, so the main thread never hashes, converts images or touches the database (FR-001-17). Capture has
/// no persistence code of its own.
///
/// Tick cost (FR-001-01): one `changeCount` comparison, nothing else, until the count changes. While Paused (FR-001-19)
/// the 0.5 s poll does not run at all: the timer slows to the cadence `PollTick` gives the work still registered with
/// it (the watchdog, the re-resolve), and resuming re-baselines `changeCount` so nothing copied during the pause is
/// captured.
@MainActor
public final class ClipboardCapture {
    /// FR-001-01. The values live with the tick every periodic job shares (`PollTick`).
    static let pollInterval = PollTick.interval
    static let pollTolerance = PollTick.tolerance
    /// FR-001-18: consecutive changes that return no type data before capture suspends.
    static let emptyReadsBeforeSuspension = 3
    /// FR-001-01: how long (seconds, counted from the poll that first saw the change) one `changeCount` that reads
    /// empty is watched: re-read on every tick until data lands, a newer change arrives, or this much time has passed.
    /// A copy is not atomic: `clearContents` bumps the count, and `writeObjects` or `setData` fills the board without a
    /// second bump, so a poll in between sees a new count and nothing to read. Re-reading catches the data when it
    /// lands instead of dropping the copy until the user copies something else. Only a change still empty when its
    /// watch ends counts as an empty change (FR-001-18 b).
    static let emptyChangeWatchLimit: TimeInterval = 10
    /// FR-001-18: how often a suspended capture re-probes the pasteboard.
    static let suspendedProbeInterval: TimeInterval = 60

    private let pasteboard: any PasteboardPort
    private let access: any PasteboardAccessPort
    private let sourceApps: any SourceAppPort
    private let ownWrites: OwnWriteLedger
    private let settings: SettingsStore
    private let ignoredApps: () -> Set<String>
    private let reporter: ErrorReporter
    private let clock: any WallClock
    private let sink: any LogSink
    private let ingest: IngestActor
    /// Seals concealed copies (FR-001-04 gate 3). Nil means no secure storage is wired: a concealed copy is then
    /// rejected `CAP-POL-001`, the same as a missing key (fails closed).
    private let vault: (any SecureClipVaulting)?
    private let pollTick: PollTick

    private let scheduleTimer: TimerScheduler
    /// Cancels the one scheduled timer source; nil when none is scheduled.
    private var cancelTimer: (@MainActor () -> Void)?
    /// The interval `timer` was scheduled at, which is `pollTick.cadence` as of the last `syncTimer()`.
    private var timerCadence: TimeInterval?
    private var isStarted = false
    /// FR-001-19: capture mode is Paused, so the poll is skipped and `PollTick` is told the 0.5 s tick is not needed.
    private var isPollPaused = false
    private var unsubscribeSettings: (@Sendable () -> Void)?
    private var continuation: AsyncStream<CapturedPayload>.Continuation?
    private var consumer: Task<Void, Never>?

    private var lastProcessedChangeCount: Int?
    private var consecutiveEmptyReads = 0
    /// The change whose reads have all come back empty so far and that is still being re-read (FR-001-01), and when the
    /// poll first saw it. At most one: a newer change ends the watch of the one before.
    private struct EmptyWatch {
        let changeCount: Int
        let began: Date
    }
    private var emptyWatch: EmptyWatch?
    /// The last `changeCount` that was counted as an empty change. FR-001-18 b counts changeCount increments, so a
    /// second read of the same count (Save Clipboard pressed again, a suspended probe) is not another.
    private var lastCountedEmptyChangeCount: Int?
    private var suspendedSince: Date?
    private var lastProbe = Date.distantPast

    /// `ignoredApps` supplies the bundle identifiers FR-001-04 gate 4 rejects; the registry and its defaults belong
    /// to FRD-008, so Capture neither stores nor defaults a list.
    public init(
        pasteboard: any PasteboardPort, sourceApps: any SourceAppPort, ownWrites: OwnWriteLedger,
        ingest: IngestActor, settings: SettingsStore, reporter: ErrorReporter,
        ignoredApps: @escaping () -> Set<String>,
        access: any PasteboardAccessPort,
        vault: (any SecureClipVaulting)? = nil,
        clock: any WallClock = SystemClock(), sink: any LogSink = OSLogSink(), pollTick: PollTick = PollTick(),
        scheduleTimer: @escaping TimerScheduler = ClipboardCapture.systemTimer
    ) {
        self.vault = vault
        self.scheduleTimer = scheduleTimer
        self.pasteboard = pasteboard
        self.access = access
        self.sourceApps = sourceApps
        self.ownWrites = ownWrites
        self.ingest = ingest
        self.settings = settings
        self.reporter = reporter
        self.ignoredApps = ignoredApps
        self.clock = clock
        self.sink = sink
        self.pollTick = pollTick
    }

    /// The ingest worker, reading `capture.autoBundle` at each payload so a change applies to the next copy (FR-001-12).
    private func makeWorker() -> IngestWorker {
        let settings = settings
        return IngestWorker(
            ingest: ingest, reporter: reporter, sink: sink, vault: vault,
            autoBundle: { settings.value(SettingKeys.captureAutoBundle) })
    }

    // MARK: Lifecycle

    /// Starts the poll and the ingest consumer, then runs the launch check (FR-001-02 d). When the system reports an
    /// access behaviour other than "Allow", capture starts suspended with `CAP-PRM-001` (FR-001-18 a).
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        let (stream, continuation) = AsyncStream<CapturedPayload>.makeStream()
        self.continuation = continuation
        let worker = makeWorker()
        consumer = Task.detached(priority: .utility) {
            for await payload in stream { await worker.handle(payload) }
        }

        // FR-001-19: the mode decides whether the poll runs; the timer follows the cadence `PollTick` reports.
        unsubscribeSettings = settings.subscribe { [weak self] change in
            guard change.name == SettingKeys.captureMode.name else { return }
            // The store calls handlers before `set` returns. On the main thread apply the mode right there, so the
            // baseline is read at the change and no check can run between the change and the re-baseline; from any
            // other thread hop, and `captureNow` re-baselines first if it gets there before the hop does.
            if Thread.isMainThread {
                MainActor.assumeIsolated { _ = self?.applyMode() }
            } else {
                Task { @MainActor in self?.applyMode() }
            }
        }
        pollTick.observeCadence { [weak self] in Task { @MainActor in self?.syncTimer() } }
        isPollPaused = settings.value(SettingKeys.captureMode) == .paused
        pollTick.setFastTickNeeded(!isPollPaused)
        syncTimer()
        if !access.isReadAllowed { raise(beginSuspension(reason: "pasteboard access is not Allow")) }
        captureNow()
    }

    /// One firing of the shared timer: the pasteboard poll (skipped while Paused, FR-001-19), then the slower periodic
    /// work (S5, ADR-0004). The poll goes first.
    func timerFired() {
        guard isStarted else { return }  // a firing delivered after stop() does no work (TASK-430 OC-430-05)
        if !isPollPaused { poll() }
        pollTick.fire()
    }

    /// FR-001-19: enters or leaves Paused. Pausing stops the poll and lets `PollTick` slow the timer. Resuming brings
    /// the 0.5 s cadence back and runs one immediate check against a baseline re-read now, so a change made while
    /// Paused is never captured. Idempotent: only a change of Paused does anything. Returns whether it changed.
    /// Also called from `captureNow` (the settings subscription reaches here through a main-actor hop, so a check can
    /// land after the mode changed but before this ran) so the baseline is re-read before anything is compared.
    @discardableResult
    func applyMode() -> Bool {
        guard isStarted else { return false }
        let paused = settings.value(SettingKeys.captureMode) == .paused
        guard paused != isPollPaused else { return false }
        isPollPaused = paused
        pollTick.setFastTickNeeded(!paused)
        syncTimer()
        guard !paused else { return true }
        lastProcessedChangeCount = pasteboard.changeCount
        emptyWatch = nil
        captureNow()
        return true
    }

    /// The interval the timer is scheduled at now, or nil when it is not scheduled. Exposed for tests.
    var scheduledTimerInterval: TimeInterval? { cancelTimer == nil ? nil : timerCadence }

    /// ADR-0011 seam: schedules a repeating timer at `interval` (with `tolerance`) that calls `fire` on the main actor,
    /// and returns the function that cancels it. Tests pass a fake to count sources and fire them by hand.
    public typealias TimerScheduler = @MainActor (_ interval: TimeInterval, _ tolerance: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void

    /// The production scheduler: a `Timer` on the main run loop in `.common` mode so it keeps firing while a menu is
    /// tracked (FR-001-01).
    public static let systemTimer: TimerScheduler = { interval, tolerance, fire in
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { fire() }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    /// Schedules the one timer at `pollTick.cadence`: rescheduled when the cadence changes, removed when nothing needs
    /// a firing. There is never more than one timer.
    private func syncTimer() {
        guard isStarted else { return }
        let wanted = pollTick.cadence
        if cancelTimer != nil, timerCadence == wanted { return }
        cancelTimer?()
        cancelTimer = nil
        timerCadence = wanted
        guard let wanted else { return }
        cancelTimer = scheduleTimer(wanted, Self.pollTolerance) { [weak self] in self?.timerFired() }
    }

    /// Stops polling and returns once every payload already handed off has been ingested.
    public func stop() async {
        isStarted = false
        unsubscribeSettings?()
        unsubscribeSettings = nil
        cancelTimer?()
        cancelTimer = nil
        timerCadence = nil
        continuation?.finish()
        continuation = nil
        await consumer?.value
        consumer = nil
    }

    /// FR-001-02: one synchronous check, called before the Library or Shelf shows, on wake, on activation and at
    /// launch. Idempotent (an unchanged `changeCount` returns at once) and returns after the item is queued, not
    /// after it is persisted. While suspended (FR-001-18) it is also the retry.
    public func captureNow() {
        // A Paused to Active change not yet applied re-baselines here (and runs its own check), never compares first.
        if applyMode() { return }
        poll(retrySuspended: suspendedSince != nil)
    }

    // MARK: Poll

    private func poll(retrySuspended: Bool = false) {
        let changeCount = pasteboard.changeCount
        let probeDue = suspendedSince != nil && (retrySuspended || clock.now().timeIntervalSince(lastProbe) >= Self.suspendedProbeInterval)
        // A watched change is visited on every tick until its watch ends, in `handleChange`.
        guard changeCount != lastProcessedChangeCount || probeDue || emptyWatch != nil else { return }
        lastProcessedChangeCount = changeCount
        lastProbe = clock.now()
        handleChange(changeCount: changeCount)
    }

    /// Why a pasteboard change produced no payload. `silent` is a change counted toward privacy suspension that has
    /// already been reported (or is deliberately quiet while suspended), or an empty read that is still being retried.
    private enum Rejection: Error {
        case skipped(ErrorCode)
        case failed(FlotsamError)
        case silent(ErrorCode)
    }

    /// FR-001-04 gate 1 on a poll, then the rest through `gather`. Rejections are logged or raised as background reports.
    private func handleChange(changeCount: Int) {
        guard settings.value(SettingKeys.captureMode).capturesClipboardAutomatically else {
            return skip(.capPol003)
        }
        if endWatchIfFinished(at: changeCount) { return }
        switch gather(changeCount: changeCount, rereadEmpty: true) {
        case .success(let payload): continuation?.yield(payload)
        case .failure(let rejection): report(rejection)
        }
    }

    private func report(_ rejection: Rejection) {
        switch rejection {
        case .skipped(let policy): skip(policy)
        case .failed(let error): raise(error)
        case .silent: break
        }
    }

    /// Ends the empty-change watch (FR-001-01) when it is over, counting the change as an empty change (FR-001-18 b),
    /// which is the only moment a watched change counts: one that fills in time is a readable change and never was
    /// empty. A watch is over when a newer change has arrived (`changeCount` differs) or when `emptyChangeWatchLimit`
    /// has passed since it began. Reads made at or after the limit are outside the watch, so the tick that finds it
    /// over does not read again. Returns whether it ended by running out of time, which is when this tick must not
    /// read the change.
    private func endWatchIfFinished(at changeCount: Int) -> Bool {
        guard let watch = emptyWatch else { return false }
        let timedOut = changeCount == watch.changeCount
            && clock.now().timeIntervalSince(watch.began) >= Self.emptyChangeWatchLimit
        guard timedOut || changeCount != watch.changeCount else { return false }
        emptyWatch = nil
        report(countEmptyChange(watch.changeCount))
        return timedOut
    }

    /// FR-001-04 gates 2 to 5 and the read, in order, stopping at the first that rejects. Gates 2 to 4 read type
    /// identifiers and the source marker; payload bytes are read only after all of them pass. The one home of those
    /// gates: a poll (`handleChange`) and Save Clipboard (`saveClipboardNow`) both go through it (Rule 9).
    private func gather(changeCount: Int, rereadEmpty: Bool) -> Result<CapturedPayload, Rejection> {
        if ownWrites.contains(changeCount: changeCount) { return .failure(.skipped(.capPol004)) }

        let types = pasteboard.currentTypeIdentifiers()
        if types.isEmpty { return .failure(noteEmptyRead(changeCount: changeCount, rereading: rereadEmpty)) }
        // Listed types are readable type data, so every exit below marks readable (and resumes a suspension) except
        // the one where the snapshot then yields no bytes: that is an empty read, counted by `noteEmptyRead` like an
        // empty type list (FR-001-18 b), and must not reset `consecutiveEmptyReads` on the way.
        var readable = true
        defer { if readable { _ = noteReadability(.readable) } }
        if types.contains(PasteboardMarkers.ownWrite) { return .failure(.skipped(.capPol004)) }
        if types.contains(where: PasteboardMarkers.neverStoreAtCapture.contains) { return .failure(.skipped(.capPol001)) }
        // Gate 3, concealed: a password manager's copy is kept, encrypted, and only its plain text. Without the vault
        // or without plain text there is nothing safe to keep, so it is rejected exactly as before (fails closed).
        let isConcealed = types.contains(PasteboardMarkers.concealed)
        if isConcealed, vault == nil || !types.contains(PasteboardTypes.plainText) {
            return .failure(.skipped(.capPol001))
        }

        let source = resolveSource(types: types)
        if let bundleId = source?.bundleId, ignoredApps().contains(bundleId) { return .failure(.skipped(.capPol002)) }
        guard PasteboardTypes.hasHonoured(in: types) else {
            return .failure(.failed(FlotsamError(.capVal001, "pasteboard holds no honoured type")))
        }

        let snapshot: PasteboardSnapshot
        // A concealed copy reads only its plain text: no other representation of a password is ever held in memory.
        let typesToRead = isConcealed ? [PasteboardTypes.plainText] : PasteboardTypes.typesToRead(from: types)
        switch pasteboard.readSnapshot(types: typesToRead) {
        case .failure(let error):
            // FR-001-22: one bad read drops this change; the timer carries on.
            return .failure(.failed(FlotsamError(.capOs001, "pasteboard read failed", underlying: error.underlying)))
        case .success(let value):
            guard value.changeCount == changeCount else {
                return .failure(.failed(FlotsamError(.capOs001, "pasteboard changed during read")))
            }
            snapshot = value
        }
        if snapshot.representations.isEmpty {
            readable = false
            return .failure(noteEmptyRead(changeCount: changeCount, rereading: rereadEmpty))
        }
        emptyWatch = nil

        return .success(CapturedPayload(
            representations: snapshot.representations, source: source, capturedAt: clock.now(), origin: .pasteboard,
            isConcealed: isConcealed))
    }

    // MARK: Save Clipboard (FR-005-06)

    /// Reads the pasteboard now and runs gates 2 to 5 and the ingest pipeline on it whatever the capture mode, so it
    /// also works while Paused or Curated. A clip already stored is deduplicated and counts as saved. The result is
    /// returned for the caller to show; a rejection is not also raised as a Notice.
    public func saveClipboardNow() async -> SaveClipboardOutcome {
        let changeCount = pasteboard.changeCount
        // This change is handled here, so the poll must not ingest it a second time.
        lastProcessedChangeCount = changeCount
        emptyWatch = nil
        switch gather(changeCount: changeCount, rereadEmpty: false) {
        case .failure(.skipped(let policy)):
            return .rejected(FlotsamError(policy, "Save Clipboard: the pasteboard change was skipped by policy"))
        case .failure(.failed(let error)):
            return .rejected(error)
        case .failure(.silent(let code)):
            return .rejected(FlotsamError(code, "Save Clipboard: pasteboard reads return no data"))
        case .success(let payload):
            let worker = makeWorker()
            if let error = await worker.handle(payload, reportingFailure: false) { return .rejected(error) }
            return .saved
        }
    }

    // MARK: Source (FR-001-13, FR-001-14)

    private func resolveSource(types: [String]) -> SourceApp? {
        if types.contains(PasteboardMarkers.remoteClipboard) {
            return SourceApp(bundleId: nil, name: SourceApp.anotherDeviceName)
        }
        if types.contains(PasteboardMarkers.source),
           case .success(let snapshot) = pasteboard.readSnapshot(types: [PasteboardMarkers.source]),
           let data = snapshot.representations.first(where: { $0.uti == PasteboardMarkers.source })?.data {
            let bundleId = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !bundleId.isEmpty {
                return SourceApp(bundleId: bundleId, name: sourceApps.localizedName(forBundleId: bundleId))
            }
        }
        if let frontmost = sourceApps.frontmostApp() { return frontmost }
        // Stored as Unknown (no source); the capture itself still succeeds.
        FlotsamLog.log(FlotsamError(.capOs002, "source app unresolvable"), sink: sink)
        return nil
    }

    // MARK: Privacy suspension (FR-001-18 b)

    private enum Readability { case readable, empty }

    /// An empty read of `changeCount`. When `rereading` (a poll) the change is not counted yet: the first empty read
    /// opens its watch (`emptyWatch`) and every later tick reads it again until the watch ends
    /// (`endWatchIfFinished`), which is when it counts as an empty change (FR-001-18 b). Save Clipboard does not
    /// reread (nothing will tick again for it): its empty read is counted and reported at once. Either way a
    /// `changeCount` counts as an empty change once: a repeat read of the same count (three Save Clipboard presses on
    /// one unchanged empty pasteboard, a suspended probe) is rejected as empty but not counted, and opens no watch.
    private func noteEmptyRead(changeCount: Int, rereading: Bool) -> Rejection {
        guard rereading else { return countEmptyChange(changeCount) }
        if emptyWatch?.changeCount != changeCount, changeCount != lastCountedEmptyChangeCount {
            emptyWatch = EmptyWatch(changeCount: changeCount, began: clock.now())
        }
        return .silent(.capVal001)
    }

    /// Counts `changeCount` as an empty change, once, and says what to do with it: `CAP-VAL-001` for the first two,
    /// the suspension for the third in a row. The one place a change is counted.
    private func countEmptyChange(_ changeCount: Int) -> Rejection {
        guard changeCount != lastCountedEmptyChangeCount else { return .silent(.capVal001) }
        lastCountedEmptyChangeCount = changeCount
        // `.empty` always yields a rejection; the fallback only satisfies the optional.
        return noteReadability(.empty) ?? .silent(.capVal001)
    }

    /// Counts changes that yield no type data. Returns nil to go on, or why the change should not go further (it was
    /// empty). Three in a row suspend capture with `CAP-PRM-001`; the first readable change afterwards resumes it.
    private func noteReadability(_ readability: Readability) -> Rejection? {
        switch readability {
        case .readable:
            consecutiveEmptyReads = 0
            if suspendedSince != nil {
                suspendedSince = nil
                FlotsamLog.trace("capture resumed after pasteboard access returned", category: .capture, sink: sink)
                // FR-001-18: the warning clears on the first successful read.
                let reporter = reporter
                Task { await reporter.clearNotices(code: .capPrm001) }
            }
            return nil
        case .empty:
            consecutiveEmptyReads += 1
            if consecutiveEmptyReads >= Self.emptyReadsBeforeSuspension, suspendedSince == nil {
                return .failed(beginSuspension(reason: "pasteboard reads return no data"))
            } else if suspendedSince == nil {
                return .failed(FlotsamError(.capVal001, "pasteboard change carries no data"))
            }
            return .silent(.capVal001)
        }
    }

    /// Suspends capture and returns the `CAP-PRM-001` to raise, for either trigger of FR-001-18 (a launch-time access
    /// check, b empty reads). The one place the suspension begins.
    private func beginSuspension(reason: StaticString) -> FlotsamError {
        suspendedSince = clock.now()
        return FlotsamError(.capPrm001, reason, context: [.permission: .permission(.pasteboard)])
    }

    // MARK: Reporting

    /// Every skip and raise is final for the change it handled, so it ends any watch of that change (FR-001-22). A watch
    /// left open would re-handle the same `changeCount` on every tick. Clearing here, not at the read, keeps the watch of
    /// a change whose types are listed but whose bytes come back empty (`noteEmptyRead` below the snapshot).
    private func skip(_ policy: ErrorCode) {
        emptyWatch = nil
        FlotsamLog.log(.pasteboardProcessed(kind: nil, byteSize: 0, outcome: .skipped, policy: policy), sink: sink)
    }

    private func raise(_ error: FlotsamError) {
        emptyWatch = nil
        let reporter = reporter
        Task { await reporter.report(error, origin: .background) }
    }
}

extension ClipboardCapture: ClipboardSaver {}
