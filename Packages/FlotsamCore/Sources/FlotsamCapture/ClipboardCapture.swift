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
        clock: any WallClock = SystemClock(), sink: any LogSink = OSLogSink()
    ) {
        self.pasteboard = pasteboard
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

    /// Starts the poll and the ingest consumer, then runs the launch check (FR-001-02 d).
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

    /// FR-001-04: the gates, in order, stopping at the first that rejects. Gate 1 reads nothing; gates 2 to 4 read
    /// type identifiers and the source marker; payload bytes are read only after all of them pass.
    private func handleChange(changeCount: Int) {
        guard settings.value(SettingKeys.captureMode).capturesClipboardAutomatically else {
            return skip(.capPol003)
        }
        if ownWrites.contains(changeCount: changeCount) { return skip(.capPol004) }

        let types = pasteboard.currentTypeIdentifiers()
        if types.isEmpty { return noteEmptyRead(changeCount: changeCount) }
        // Listed types are readable type data, so every exit below marks readable (and resumes a suspension) except
        // the one where the snapshot then yields no bytes: that is an empty read, counted by `noteEmptyRead` like an
        // empty type list (FR-001-18 b), and must not reset `consecutiveEmptyReads` on the way.
        var readable = true
        defer { if readable { _ = noteReadability(.readable) } }
        if types.contains(PasteboardMarkers.ownWrite) { return skip(.capPol004) }
        if types.contains(where: PasteboardMarkers.neverStore.contains) { return skip(.capPol001) }

        let source = resolveSource(types: types)
        if let bundleId = source?.bundleId, ignoredApps().contains(bundleId) { return skip(.capPol002) }
        guard PasteboardTypes.hasHonoured(in: types) else {
            return raise(FlotsamError(.capVal001, "pasteboard holds no honoured type"))
        }

        let snapshot: PasteboardSnapshot
        switch pasteboard.readSnapshot(types: PasteboardTypes.typesToRead(from: types)) {
        case .failure(let error):
            // FR-001-22: one bad read drops this change; the timer carries on.
            return raise(FlotsamError(.capOs001, "pasteboard read failed", underlying: error.underlying))
        case .success(let value):
            guard value.changeCount == changeCount else {
                return raise(FlotsamError(.capOs001, "pasteboard changed during read"))
            }
            snapshot = value
        }
        if snapshot.representations.isEmpty {
            readable = false
            return noteEmptyRead(changeCount: changeCount)
        }
        rereadingChangeCount = nil

        continuation?.yield(CapturedPayload(
            representations: snapshot.representations, source: source, capturedAt: clock.now(), origin: .pasteboard))
    }

    // MARK: Source (FR-001-13, FR-001-14)

    private func resolveSource(types: [String]) -> SourceApp? {
        if types.contains(PasteboardMarkers.remoteClipboard) {
            return SourceApp(bundleId: nil, name: FlotsamStrings.text(forKey: "ui.source.remoteDevice"))
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

    /// An empty read of `changeCount`. The first `emptyAttemptsPerChange - 1` are silent and the same count is read again
    /// on the next tick; only the last one counts as an empty change (and can suspend capture, FR-001-18 b).
    private func noteEmptyRead(changeCount: Int) {
        if rereadingChangeCount != changeCount {
            rereadingChangeCount = changeCount
            emptyAttempts = 0
        }
        emptyAttempts += 1
        if emptyAttempts < Self.emptyAttemptsPerChange { return }
        rereadingChangeCount = nil
        _ = noteReadability(.empty)
    }

    /// Counts changes that yield no type data. Returns false when the change should not go further (it was empty).
    /// Three in a row suspend capture with `CAP-PRM-001`; the first readable change afterwards resumes it.
    private func noteReadability(_ readability: Readability) -> Bool {
        switch readability {
        case .readable:
            consecutiveEmptyReads = 0
            if suspendedSince != nil {
                suspendedSince = nil
                FlotsamLog.trace("capture resumed after pasteboard access returned", category: .capture, sink: sink)
            }
            return true
        case .empty:
            consecutiveEmptyReads += 1
            if consecutiveEmptyReads >= Self.emptyReadsBeforeSuspension, suspendedSince == nil {
                suspendedSince = clock.now()
                raise(FlotsamError(.capPrm001, "pasteboard reads return no data", context: [.permission: .permission(.pasteboard)]))
            } else if suspendedSince == nil {
                raise(FlotsamError(.capVal001, "pasteboard change carries no data"))
            }
            return false
        }
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
