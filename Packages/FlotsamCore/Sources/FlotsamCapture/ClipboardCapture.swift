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
/// Tick cost (FR-001-01): one `changeCount` comparison, nothing else, until the count changes.
@MainActor
public final class ClipboardCapture {
    /// FR-001-01.
    static let pollInterval: TimeInterval = 0.5
    static let pollTolerance: TimeInterval = 0.1
    /// FR-001-18: consecutive changes that return no type data before capture suspends.
    static let emptyReadsBeforeSuspension = 3
    /// FR-001-01: reads of one `changeCount` that may come back empty before the change counts as an empty change. A
    /// copy is not atomic: `clearContents` bumps the count, and `writeObjects` or `setData` fills the board without a
    /// second bump, so a poll in between sees a new count and nothing to read. Re-reading on the next ticks (about 1 s
    /// in all) catches the data when it lands instead of dropping the copy until the user copies something else.
    static let emptyAttemptsPerChange = 3
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

    private var timer: Timer?
    private var continuation: AsyncStream<CapturedPayload>.Continuation?
    private var consumer: Task<Void, Never>?

    private var lastProcessedChangeCount: Int?
    private var consecutiveEmptyReads = 0
    /// The count whose last read came back empty and is still being re-read, and how many reads it has had.
    private var rereadingChangeCount: Int?
    private var emptyAttempts = 0
    private var suspendedSince: Date?
    private var lastProbe = Date.distantPast

    /// `ignoredApps` supplies the bundle identifiers FR-001-04 gate 4 rejects; the registry and its defaults belong
    /// to FRD-008, so Capture neither stores nor defaults a list.
    public init(
        pasteboard: any PasteboardPort, sourceApps: any SourceAppPort, ownWrites: OwnWriteLedger,
        ingest: IngestActor, settings: SettingsStore, reporter: ErrorReporter,
        ignoredApps: @escaping () -> Set<String>,
        access: any PasteboardAccessPort = UngatedPasteboardAccess(),
        clock: any WallClock = SystemClock(), sink: any LogSink = OSLogSink()
    ) {
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
    }

    // MARK: Lifecycle

    /// Starts the poll and the ingest consumer, then runs the launch check (FR-001-02 d). When the system reports an
    /// access behaviour other than "Allow", capture starts suspended with `CAP-PRM-001` (FR-001-18 a).
    public func start() {
        guard timer == nil else { return }
        let (stream, continuation) = AsyncStream<CapturedPayload>.makeStream()
        self.continuation = continuation
        let worker = IngestWorker(ingest: ingest, reporter: reporter, sink: sink)
        consumer = Task.detached(priority: .utility) {
            for await payload in stream { await worker.handle(payload) }
        }

        // `.common` so the timer keeps firing while a menu is tracked (FR-001-01).
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = Self.pollTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if !access.isReadAllowed { raise(beginSuspension(reason: "pasteboard access is not Allow")) }
        captureNow()
    }

    /// Stops polling and returns once every payload already handed off has been ingested.
    public func stop() async {
        timer?.invalidate()
        timer = nil
        continuation?.finish()
        continuation = nil
        await consumer?.value
        consumer = nil
    }

    /// FR-001-02: one synchronous check, called before the Library or Shelf shows, on wake, on activation and at
    /// launch. Idempotent (an unchanged `changeCount` returns at once) and returns after the item is queued, not
    /// after it is persisted. While suspended (FR-001-18) it is also the retry.
    public func captureNow() {
        poll(retrySuspended: suspendedSince != nil)
    }

    // MARK: Poll

    private func poll(retrySuspended: Bool = false) {
        let changeCount = pasteboard.changeCount
        let probeDue = suspendedSince != nil && (retrySuspended || clock.now().timeIntervalSince(lastProbe) >= Self.suspendedProbeInterval)
        if rereadingChangeCount != changeCount { rereadingChangeCount = nil }
        let rereadDue = rereadingChangeCount != nil
        guard changeCount != lastProcessedChangeCount || probeDue || rereadDue else { return }
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
        switch gather(changeCount: changeCount, rereadEmpty: true) {
        case .success(let payload): continuation?.yield(payload)
        case .failure(.skipped(let policy)): skip(policy)
        case .failure(.failed(let error)): raise(error)
        case .failure(.silent): break
        }
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
        if types.contains(where: PasteboardMarkers.neverStore.contains) { return .failure(.skipped(.capPol001)) }

        let source = resolveSource(types: types)
        if let bundleId = source?.bundleId, ignoredApps().contains(bundleId) { return .failure(.skipped(.capPol002)) }
        guard PasteboardTypes.hasHonoured(in: types) else {
            return .failure(.failed(FlotsamError(.capVal001, "pasteboard holds no honoured type")))
        }

        let snapshot: PasteboardSnapshot
        switch pasteboard.readSnapshot(types: PasteboardTypes.typesToRead(from: types)) {
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
        rereadingChangeCount = nil

        return .success(CapturedPayload(
            representations: snapshot.representations, source: source, capturedAt: clock.now(), origin: .pasteboard))
    }

    // MARK: Save Clipboard (FR-005-06)

    /// Reads the pasteboard now and runs gates 2 to 5 and the ingest pipeline on it whatever the capture mode, so it
    /// also works while Paused or Curated. A clip already stored is deduplicated and counts as saved. The result is
    /// returned for the caller to show; a rejection is not also raised as a Notice.
    public func saveClipboardNow() async -> SaveClipboardOutcome {
        let changeCount = pasteboard.changeCount
        // This change is handled here, so the poll must not ingest it a second time.
        lastProcessedChangeCount = changeCount
        rereadingChangeCount = nil
        switch gather(changeCount: changeCount, rereadEmpty: false) {
        case .failure(.skipped(let policy)):
            return .rejected(FlotsamError(policy, "Save Clipboard: the pasteboard change was skipped by policy"))
        case .failure(.failed(let error)):
            return .rejected(error)
        case .failure(.silent(let code)):
            return .rejected(FlotsamError(code, "Save Clipboard: pasteboard reads return no data"))
        case .success(let payload):
            let worker = IngestWorker(ingest: ingest, reporter: reporter, sink: sink)
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

    /// An empty read of `changeCount`. When `rereading` (a poll), the first `emptyAttemptsPerChange - 1` are silent and
    /// the same count is read again on the next tick; only the last one counts as an empty change (and can suspend
    /// capture, FR-001-18 b). Save Clipboard does not reread (nothing will tick again for it): its empty read counts and
    /// is reported at once.
    private func noteEmptyRead(changeCount: Int, rereading: Bool) -> Rejection {
        if rereading {
            if rereadingChangeCount != changeCount {
                rereadingChangeCount = changeCount
                emptyAttempts = 0
            }
            emptyAttempts += 1
            if emptyAttempts < Self.emptyAttemptsPerChange { return .silent(.capVal001) }
            rereadingChangeCount = nil
        }
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

    /// Every skip and raise is final for the change it handled, so it ends any reread of that change (FR-001-22). A latch
    /// left set would re-handle the same `changeCount` on every tick. Clearing here, not at the read, keeps the attempt
    /// budget of a change whose types are listed but whose bytes come back empty (`noteEmptyRead` below the snapshot).
    private func skip(_ policy: ErrorCode) {
        rereadingChangeCount = nil
        FlotsamLog.log(.pasteboardProcessed(kind: nil, byteSize: 0, outcome: .skipped, policy: policy), sink: sink)
    }

    private func raise(_ error: FlotsamError) {
        rereadingChangeCount = nil
        let reporter = reporter
        Task { await reporter.report(error, origin: .background) }
    }
}

extension ClipboardCapture: ClipboardSaver {}
