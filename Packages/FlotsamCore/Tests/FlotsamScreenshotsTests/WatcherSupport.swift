import Foundation
import FlotsamBase
import FlotsamPayload
@testable import FlotsamScreenshots
@testable import FlotsamStorage

// Seams for the ScreenshotWatcher suites (FRD-002). Folders and files are real (a temporary tree, real extended
// attributes and birth dates); time, folder events, ingest, the watermark and the notices are fakes the test steers.
// `ManualClock`, `FixedPreferences` and `TempFolder` live in ScreenshotSupport.swift.

/// A clock the test steps. Waits under a second (the 0.5 s stability check) pass at once and move time forward;
/// longer waits (the 5 s poll) suspend until `advance(by:)` reaches their deadline.
final class SteppedClock: WallClock, @unchecked Sendable {
    private struct Sleeper {
        let seconds: TimeInterval
        let deadline: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []

    /// Starts at the real time so file birth dates the test sets and the watermark share one timeline.
    init(start: Date = Date()) { current = start }

    func now() -> Date { lock.withLock { current } }

    func sleep(for duration: Duration) async {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds < 1 {
            lock.withLock { current = current.addingTimeInterval(seconds) }
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if cancelled.contains(id) || Task.isCancelled { return true }
                    sleepers[id] = Sleeper(seconds: seconds, deadline: current.addingTimeInterval(seconds), continuation: continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                cancelled.insert(id)
                return sleepers.removeValue(forKey: id)
            }
            sleeper?.continuation.resume()
        }
    }

    /// Time passes: everything whose deadline is now reached wakes.
    func advance(by seconds: TimeInterval) {
        let due = lock.withLock { () -> [Sleeper] in
            current = current.addingTimeInterval(seconds)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for id in ready.keys { sleepers[id] = nil }
            return Array(ready.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// How many tasks are suspended in a wait of `seconds`.
    func sleeping(seconds: TimeInterval) -> Int { lock.withLock { sleepers.values.filter { $0.seconds == seconds }.count } }
}

/// A folder event source the test drives. Records every watch it was asked for.
final class FakeFolderSource: FolderEventSource, @unchecked Sendable {
    final class Watch: FolderWatch, @unchecked Sendable {
        let folder: URL
        let handler: @Sendable (FolderEvent) -> Void
        private let lock = NSLock()
        private var isStopped = false
        init(folder: URL, handler: @escaping @Sendable (FolderEvent) -> Void) { self.folder = folder; self.handler = handler }
        func stop() { lock.withLock { isStopped = true } }
        var stopped: Bool { lock.withLock { isStopped } }
    }

    private let lock = NSLock()
    private var created: [Watch] = []
    private var failing = false

    /// While true, `start` fails: the mechanism is unavailable (FR-002-04).
    func setFailing(_ value: Bool) { lock.withLock { failing = value } }

    func start(watching folder: URL, handler: @escaping @Sendable (FolderEvent) -> Void) -> FlotsamResult<any FolderWatch> {
        if lock.withLock({ failing }) { return .failure(FlotsamError(.sspOs001, "Fake source unavailable")) }
        let watch = Watch(folder: folder, handler: handler)
        lock.withLock { created.append(watch) }
        return .success(watch)
    }

    var watches: [Watch] { lock.withLock { created } }
    var running: [Watch] { watches.filter { !$0.stopped } }

    /// Delivers `event` on `watch`, by default the newest. A stopped watch still delivers: a real stream cannot, but
    /// the watcher must not rely on that.
    func emit(_ event: FolderEvent, on watch: Watch? = nil) {
        (watch ?? watches.last)?.handler(event)
    }
}

/// Stands in for the ingest pipeline: records each candidate, creates an item for new content and reports a repeat
/// as bumped (a copy) or unchanged (backfill), like `IngestActor`. Failures are scripted per file name.
final class IngestRecorder: ScreenshotIngesting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [IngestCandidate] = []
    private var keys: Set<String> = []
    private var scripted: [String: FlotsamError] = [:]
    private var running = 0
    private var peak = 0

    func fail(_ fileName: String, with error: FlotsamError) { lock.withLock { scripted[fileName] = error } }

    func ingest(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult> {
        lock.withLock {
            running += 1
            peak = max(peak, running)
        }
        // Long enough for a second import to start, so the in-flight bound is observable.
        try? await Task.sleep(for: .milliseconds(5))
        let name = URL(fileURLWithPath: candidate.originalPath ?? "").lastPathComponent
        let outcome = lock.withLock { () -> FlotsamResult<IngestResult> in
            running -= 1
            recorded.append(candidate)
            if let error = scripted[name] { return .failure(error) }
            let id = UUID()
            if keys.insert(candidate.contentKey).inserted { return .success(IngestResult(outcome: .created(id), warnings: [])) }
            return .success(IngestResult(outcome: candidate.countsAsCopy ? .bumped(id) : .unchanged(id), warnings: []))
        }
        return outcome
    }

    var candidates: [IngestCandidate] { lock.withLock { recorded } }
    var names: [String] { candidates.map { URL(fileURLWithPath: $0.originalPath ?? "").lastPathComponent } }
    var peakInFlight: Int { lock.withLock { peak } }
}

/// `meta.screenshots.lastScanAt` in memory; shared between two watchers it is the persisted watermark across a relaunch.
final class MemoryWatermarkStore: ScreenshotWatermarkStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date?
    init(_ initial: Date? = nil) { stored = initial }
    var value: Date? { lock.withLock { stored } }
    func lastScanAt() async -> FlotsamResult<Date?> { .success(lock.withLock { stored }) }
    func setLastScanAt(_ date: Date) async -> FlotsamResult<Void> {
        lock.withLock { stored = date }
        return .success(())
    }
}

/// The conditions the watcher raised and cleared, in order.
final class NoticeLog: @unchecked Sendable {
    enum Entry: Equatable { case raised(ErrorCode), cleared(ErrorCode) }
    private let lock = NSLock()
    private var recorded: [Entry] = []
    private var errors: [FlotsamError] = []

    func raise(_ error: FlotsamError) { lock.withLock { recorded.append(.raised(error.code)); errors.append(error) } }
    func clear(_ code: ErrorCode) { lock.withLock { recorded.append(.cleared(code)) } }

    var entries: [Entry] { lock.withLock { recorded } }
    var reported: [FlotsamError] { lock.withLock { errors } }
    func raised(_ code: ErrorCode) -> Int { entries.filter { $0 == .raised(code) }.count }
    func cleared(_ code: ErrorCode) -> Int { entries.filter { $0 == .cleared(code) }.count }
    /// Raised and not yet cleared.
    func standing(_ code: ErrorCode) -> Bool { raised(code) > cleared(code) }
}

/// Keeps every log record the watcher writes.
final class WatcherLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { recorded.append(record) } }
    var records: [LogRecord] { lock.withLock { recorded } }
}

/// `com.apple.screencapture` as the test sets it, changeable while the watcher runs.
final class MutablePreferences: ScreenCapturePreferences, @unchecked Sendable {
    private let lock = NSLock()
    private var locationValue: String?
    private var nameValue: String?
    init(location: String? = nil, name: String? = nil) { locationValue = location; nameValue = name }
    func set(location: String?) { lock.withLock { locationValue = location } }
    func location() -> String? { lock.withLock { locationValue } }
    func name() -> String? { lock.withLock { nameValue } }
}

/// The local file system, plus a count of directory listings and paths the test makes vanish (an unmounted volume).
final class ProbedFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var listed = 0
    private var hiddenPaths: Set<String> = []

    var listingCount: Int { lock.withLock { listed } }
    func hide(_ url: URL) { lock.withLock { _ = hiddenPaths.insert(url.path) } }
    func unhide(_ url: URL) { lock.withLock { _ = hiddenPaths.remove(url.path) } }
    private func isHidden(_ url: URL) -> Bool {
        lock.withLock { hiddenPaths.contains { url.path == $0 || url.path.hasPrefix($0 + "/") } }
    }

    func fileExists(at url: URL) -> Bool { !isHidden(url) && real.fileExists(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { isHidden(url) ? nil : real.fileInfo(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> {
        lock.withLock { listed += 1 }
        if isHidden(url) { return .failure(FlotsamError(.sspIo001, "Folder hidden by test")) }
        return real.contentsOfDirectory(at: url)
    }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { real.removeItem(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { real.writeFile(data, to: url, permissions: permissions) }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { real.readFileNoFollow(at: url) }
    func availableCapacity(at url: URL) -> Int64? { real.availableCapacity(at: url) }
}

/// In-memory settings backing store.
final class MemorySettingsBacking: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// Polls until `condition` holds or `timeout` passes. For effects that arrive through a spawned task.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Real time for a thing that should NOT happen to have had the chance to.
func letItSettle() async { try? await Task.sleep(for: .milliseconds(150)) }

/// One watcher wired to a temporary tree. `home/Desktop` exists; every other folder is made by the test.
final class WatcherRig: @unchecked Sendable {
    let temp: TempFolder
    let home: URL
    let desktop: URL
    let clock = SteppedClock()
    let pollTick = PollTick()
    let source = FakeFolderSource()
    let ingest = IngestRecorder()
    let marks: MemoryWatermarkStore
    let notices = NoticeLog()
    let sink = WatcherLogSink()
    let preferences = MutablePreferences()
    let fileSystem = ProbedFileSystem()
    let settings = SettingsStore(store: MemorySettingsBacking())
    private(set) var watcher: ScreenshotWatcher!

    init(watermark: Date? = nil) throws {
        temp = try TempFolder()
        home = try temp.folder("home")
        desktop = try temp.folder("home/Desktop")
        marks = MemoryWatermarkStore(watermark)
        watcher = makeWatcher()
    }

    private func makeWatcher() -> ScreenshotWatcher {
        let notices = notices
        return ScreenshotWatcher(
            fileSystem: fileSystem, preferences: preferences, home: home, clock: clock, eventSource: source,
            settings: settings, ingest: ingest, watermarkStore: marks,
            report: { notices.raise($0) }, clear: { notices.clear($0) }, pollTick: pollTick, sink: sink)
    }

    /// A new launch: a fresh watcher over the same folders, watermark and ingest.
    func relaunch() { watcher = makeWatcher() }

    func cleanUp() {
        // A test may leave a folder or file unreadable on purpose.
        if let walker = FileManager.default.enumerator(at: temp.root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        temp.cleanUp()
    }

    /// A system-style screenshot: unique bytes, the screen-capture attribute, born at `born`.
    @discardableResult
    func shot(
        in folder: URL, _ name: String = "Screenshot \(UUID().uuidString).png", born: Date? = nil, attribute: Bool? = true
    ) throws -> URL {
        let url = try temp.file(
            folder.path.replacingOccurrences(of: temp.root.path + "/", with: "") + "/" + name,
            bytes: Data(UUID().uuidString.utf8), screenCapture: attribute)
        try FileManager.default.setAttributes([.creationDate: born ?? clock.now()], ofItemAtPath: url.path)
        return url
    }

    func use(_ folder: URL) { preferences.set(location: folder.path) }

    func event(_ url: URL) { source.emit(.changed([url])) }

    /// One 30 s tick, finished: time moves on and the tick's work runs to its end (the poll's timer is not in play;
    /// the watcher's `PollTick` registration is driven by `rig.pollTick`).
    func tick() async {
        clock.advance(by: ScreenshotWatcher.tickInterval)
        await watcher.tickFired()
    }

    /// One 5 s poll of the fallback source, started (its effect arrives through the watcher's task).
    func poll() async {
        _ = await eventually { clock.sleeping(seconds: 5) >= 1 }
        clock.advance(by: 5)
    }
}
