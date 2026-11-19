import CoreGraphics
import FlotsamBase
import FlotsamPayload
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FlotsamScreenshots
@testable import FlotsamStorage

// TASK-230: FRD-002 FR-002-14 performance contracts OC-2067 (p95 arrival -> Library search) and OC-2068 (idle cost), plus
// AC-002-11 (20 screenshots in 10 s: all imported, at most 2 in flight, p95 holds). Every expectation is a literal from
// the contract. The pipeline under test is the production one end to end: `ScreenshotWatcher` over the real folder, real
// `StabilityCheck` on the real clock, real `IngestActor`, real `FlotsamDatabase`, observed through `items(matching:)`
// (what the Library search reads), not through an in-memory list.
//
// What is real and what is stood in:
// - FSEvents lives in the App target and cannot be linked into package tests. `PerfEventSource` delivers the same
//   `.changed([url])` the FSEvents adapter does after the adapter's configured 0.3 s latency (App/Platform
//   FSEventsFolderSource), so FR-002-14's "0.3 s event latency" term is reproduced, not skipped.
// - OC-2067 spaces files by waiting for each to become searchable instead of idling 3 s between them: the 3 s gap only
//   guarantees the imports do not overlap, which waiting for completion guarantees as well, and latency per file is
//   unchanged. Honest deviation: 100 files over ~90 s instead of ~300 s.
// - OC-2068's "10 minutes under a CPU profile" cannot be a pass/fail unit test (process CPU is noisy under parallel
//   suites). It is asserted as what produces the CPU: no work between the 30 s ticks, no timers or sleeps of its own, no
//   directory listing, over 10 simulated minutes of the shared 0.5 s poll tick. The residual real-CPU clause needs
//   Instruments and is reported as a gap on TASK-230.

// MARK: Fixtures

/// A decodable PNG with random pixels, so every file has unique bytes (no dedupe).
private func perfPNG() -> Data {
    let width = 16, height = 12
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in pixels.indices where index % 4 != 3 { pixels[index] = UInt8.random(in: 0...255) }
    let image = pixels.withUnsafeMutableBytes { raw -> CGImage in
        CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    }
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "the test PNG must encode")
    return out as Data
}

/// Delivers `.changed` to the watcher's handler the way FSEvents does: `latency` after the file appeared.
private final class PerfEventSource: FolderEventSource, @unchecked Sendable {
    private final class Watch: FolderWatch, @unchecked Sendable { func stop() {} }
    private let lock = NSLock()
    private var handler: (@Sendable (FolderEvent) -> Void)?
    private var starts = 0
    let latency: Duration

    init(latency: Duration = .milliseconds(300)) { self.latency = latency }

    var startCount: Int { lock.withLock { starts } }

    func start(watching folder: URL, handler: @escaping @Sendable (FolderEvent) -> Void) -> FlotsamResult<any FolderWatch> {
        lock.withLock { starts += 1; self.handler = handler }
        return .success(Watch())
    }

    /// The file is already in the folder; the event follows after the stream latency.
    func deliver(_ url: URL) {
        let handler = lock.withLock { self.handler }
        let latency = latency
        Task {
            try? await Task.sleep(for: latency)
            handler?(.changed([url]))
        }
    }
}

private final class PerfPreferences: ScreenCapturePreferences, @unchecked Sendable {
    let folder: String
    init(folder: URL) { self.folder = folder.path }
    func location() -> String? { folder }
    func name() -> String? { nil }
}

private final class PerfSettingsBacking: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

private struct PerfNullSink: LogSink { func write(_ record: LogRecord) {} }

/// Counts every call the watcher makes on the file system, by name.
private final class PerfCountingFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private func note(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    func count(_ name: String) -> Int { lock.withLock { counts[name, default: 0] } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
    var snapshot: [String: Int] { lock.withLock { counts } }

    func fileExists(at url: URL) -> Bool { note("fileExists"); return real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { note("createDirectory"); return real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { note("copyItem"); return real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { note("moveItem"); return real.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with source: URL) -> FlotsamResult<Void> { note("replaceItem"); return real.replaceItem(at: destination, with: source) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { note("removeItem"); return real.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { note("contentsOfDirectory"); return real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { note("extendedAttribute"); return real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { note("writeFile"); return real.writeFile(data, to: url, permissions: permissions) }
    func readFile(at url: URL) -> FlotsamResult<Data> { note("readFile"); return real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { note("readFileNoFollow"); return real.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { note("fileInfo"); return real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { note("availableCapacity"); return real.availableCapacity(at: url) }
}

/// A clock the test moves. `sleep` is counted (a pickup that sleeps while idle is polling) and yields briefly in real
/// time so a mutant that loops on it cannot spin a core.
private final class PerfManualClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleeps = 0
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    var sleepCount: Int { lock.withLock { sleeps } }
    func sleep(for duration: Duration) async {
        lock.withLock { sleeps += 1 }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Records how many ingests run at once, and can hold them (a gate) so the concurrency ceiling becomes observable.
private final class PerfConcurrencyIngest: ScreenshotIngesting, @unchecked Sendable {
    private let inner: any ScreenshotIngesting
    private let lock = NSLock()
    private var running = 0
    private var peakRunning = 0
    private var gated = false
    private var completed = 0

    init(_ inner: any ScreenshotIngesting) { self.inner = inner }

    func hold() { lock.withLock { gated = true } }
    func release() { lock.withLock { gated = false } }
    var peak: Int { lock.withLock { peakRunning } }
    var current: Int { lock.withLock { running } }
    var finished: Int { lock.withLock { completed } }

    func ingest(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult> {
        lock.withLock { running += 1; peakRunning = max(peakRunning, running) }
        while lock.withLock({ gated }) { try? await Task.sleep(for: .milliseconds(10)) }
        let result = await inner.ingest(candidate)
        lock.withLock { running -= 1; completed += 1 }
        return result
    }
}

/// The real pipeline over a temporary tree: watched folder, real database, real watcher. Pickup is on, capture mode
/// Active (both defaults), the folder resolved and listable.
private final class PerfPickupRig: @unchecked Sendable {
    let root: URL
    let watched: URL
    let dataFolder: URL
    let source: PerfEventSource
    let fileSystem = PerfCountingFileSystem()
    let clock: any WallClock
    let pollTick = PollTick()
    let settings = SettingsStore(store: PerfSettingsBacking())
    private(set) var database: FlotsamDatabase!
    private(set) var ingest: PerfConcurrencyIngest!
    private(set) var watcher: ScreenshotWatcher!

    init(clock: any WallClock = SystemClock(), latency: Duration = .milliseconds(300)) throws {
        self.clock = clock
        source = PerfEventSource(latency: latency)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotsam-oc2067-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        watched = root.appendingPathComponent("Shots", isDirectory: true)
        dataFolder = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Opens the library with `items` text items already in it, then starts pickup. The watermark is an hour back, as a
    /// previous run would have left it, so a file arriving now is newer than it.
    func launch(libraryItems items: Int) async throws {
        database = try await FlotsamDatabase.open(folder: dataFolder, clock: clock, logSink: PerfNullSink()).get()
        try await seed(items)
        let database = self.database!
        _ = await DatabaseWatermarkStore(database: database).setLastScanAt(clock.now().addingTimeInterval(-3_600))
        ingest = PerfConcurrencyIngest(IngestActor(database: database, settings: settings))
        watcher = ScreenshotWatcher(
            fileSystem: fileSystem, preferences: PerfPreferences(folder: watched), home: root, clock: clock,
            eventSource: source, settings: settings, ingest: ingest,
            watermarkStore: DatabaseWatermarkStore(database: database),
            report: { _ in }, clear: { _ in }, pollTick: pollTick, sink: PerfNullSink())
        await watcher.start()
    }

    private func seed(_ items: Int) async throws {
        guard items > 0 else { return }
        let now = Int64(1_700_000_000_000)
        try await database.pool.write { db in
            for n in 1...items {
                let text = "seeded library item \(n)"
                try db.execute(
                    sql: """
                        INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, searchText, byteSize, pinned, updatedAt)
                        VALUES (?, 'text', ?, ?, ?, ?, ?, 0, 0, ?)
                        """,
                    arguments: [UUID().uuidString, now - Int64(n), now - Int64(n), "seed-key-\(n)", text, text, now])
            }
        }
    }

    /// macOS delivery: written under a hidden name with the screen-capture attribute, then renamed into place. Returns
    /// the final URL; the event follows after the source's latency.
    @discardableResult
    func arrive(named name: String) throws -> URL {
        let hidden = watched.appendingPathComponent(".\(UUID().uuidString).tmp")
        try perfPNG().write(to: hidden)
        try TempFolder.setScreenCaptureAttribute(true, on: hidden)
        let final = watched.appendingPathComponent(name)
        try FileManager.default.moveItem(at: hidden, to: final)
        source.deliver(final)
        return final
    }

    /// What the Library search returns for `text`.
    func searchRows(_ text: String) async -> [ItemRow] {
        (try? await database.items(matching: LibraryQuery(text: text)).get().rows) ?? []
    }

    func libraryCount() async -> Int { (try? await database.items(matching: LibraryQuery()).get().totalCount) ?? -1 }

    /// Waits until `name` is returned by Library search; its elapsed time since `from`, or nil on timeout.
    func secondsUntilSearchable(_ name: String, from start: ContinuousClock.Instant, timeout: Duration = .seconds(15)) async -> Double? {
        let deadline = start + timeout
        while ContinuousClock.now < deadline {
            if await !searchRows(name).isEmpty {
                let elapsed = ContinuousClock.now - start
                return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

/// Nearest-rank percentile: the smallest value with at least `fraction` of the samples at or below it.
private func perfPercentile(_ samples: [Double], _ fraction: Double) -> Double {
    // No sample means nothing became searchable: never inside any budget, and no out-of-range crash to hide the other checks.
    guard !samples.isEmpty else { return .infinity }
    let sorted = samples.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[max(rank, 1) - 1]
}

// MARK: Tests

@Suite("OC-2067 / OC-2068 / AC-002-11: screenshot pickup performance (FR-002-14)")
struct Oc2067Oc2068PerformanceTests {
    /// OC-2067 (FR-002-14). Given pickup on, Active, folder resolved, 10,000 library items; when 100 final screenshots
    /// arrive one at a time; then p95 from arrival to being returned by Library search is <= 2.0 s.
    /// Red if: the stability check interval or any pipeline step is slowed past the 2.0 s budget (p95 > 2.0), a file is
    /// never imported (nil latency -> count != 100), the import stops reaching the searchable index, or the 10,000-item
    /// library makes the search itself slow.
    @Test("OC-2067 p95 from arrival to Library search is at most 2.0 s over 100 screenshots with 10,000 items")
    func p95ArrivalToSearchableWithinTwoSeconds() async throws {
        // given: 10,000 items in the library, pickup running over the real folder
        let rig = try PerfPickupRig()
        defer { rig.cleanUp() }
        try await rig.launch(libraryItems: 10_000)
        #expect(await rig.libraryCount() == 10_000, "the library starts with exactly the 10,000 seeded items")
        #expect(rig.source.startCount == 1, "pickup is watching the folder before the first file arrives")

        // when: 100 final files arrive one after another, each timed from the rename to Library-search visibility
        var seconds: [Double] = []
        var missing: [String] = []
        for index in 1...100 {
            let name = "Screenshot oc2067-\(index)-\(UUID().uuidString).png"
            #expect(await rig.searchRows(name).isEmpty, "file \(index) is not searchable before it arrives")
            let start = ContinuousClock.now
            try rig.arrive(named: name)
            if let elapsed = await rig.secondsUntilSearchable(name, from: start) { seconds.append(elapsed) } else { missing.append(name) }
        }

        // then: every file was imported, exactly once, and p95 is within the 2.0 s budget
        #expect(missing.isEmpty, "every arriving screenshot becomes searchable; missing: \(missing.count)")
        #expect(seconds.count == 100)
        #expect(await rig.libraryCount() == 10_100, "100 new items on top of the 10,000, no duplicates")
        let p95 = perfPercentile(seconds, 0.95)
        print("PERF OC-2067 p95=\(p95) min=\(seconds.min() ?? 0) max=\(seconds.max() ?? 0) n=\(seconds.count)")
        #expect(p95 <= 2.0, "p95 arrival-to-searchable \(p95) s exceeds 2.0 s (max \(seconds.max() ?? 0) s)")
        // The event latency and the stability check alone put a floor under any real pipeline; a figure below it means
        // the test timed something other than the pickup (a pre-existing row, a stale query).
        #expect((seconds.min() ?? 0) >= 0.5, "no file can be searchable before the 0.3 s event plus the stability check")
    }

    /// AC-002-11 / FR-002-13 / FR-002-14. Given 20 screenshots taken in 10 s; then all are imported, p95 time to
    /// queryable meets 2.0 s.
    /// Red if: a file in the burst is lost or imported twice, the watcher serialises the burst too tightly
    /// (maxInFlight lowered so the queue grows and p95 exceeds 2.0 s), or ingest slows past the budget.
    @Test("AC-002-11 20 screenshots taken in 10 s are all imported and p95 to searchable is at most 2.0 s")
    func burstOfTwentyInTenSecondsAllImportedWithinBudget() async throws {
        // given: an empty library, pickup running
        let rig = try PerfPickupRig()
        defer { rig.cleanUp() }
        try await rig.launch(libraryItems: 0)

        // when: 20 files arrive 0.5 s apart (10 s in all), each searched for from the moment it lands
        let tasks = Handoffs()
        var names: [String] = []
        for index in 1...20 {
            let name = "Screenshot oc-burst-\(index)-\(UUID().uuidString).png"
            names.append(name)
            let start = ContinuousClock.now
            try rig.arrive(named: name)
            let waiter = Task { await rig.secondsUntilSearchable(name, from: start) }
            tasks.add(waiter)
            try? await Task.sleep(for: .milliseconds(500))
        }
        var seconds: [Double] = []
        for task in tasks.all { if let value = await task.value { seconds.append(value) } }

        // then: all 20 stored, once each; ingest never ran more than 2 at a time; p95 within 2.0 s
        #expect(seconds.count == 20, "all 20 screenshots became searchable")
        #expect(await rig.libraryCount() == 20, "exactly 20 items, no duplicates")
        #expect(rig.ingest.finished == 20, "each of the 20 files was ingested exactly once")
        #expect(rig.ingest.peak <= 2, "no more than 2 imports in flight (FR-002-13); saw \(rig.ingest.peak)")
        let p95 = perfPercentile(seconds, 0.95)
        print("PERF AC-002-11 p95=\(p95) max=\(seconds.max() ?? 0) peakIngest=\(rig.ingest.peak)")
        #expect(p95 <= 2.0, "p95 \(p95) s exceeds 2.0 s")
        #expect(names.count == 20)
    }

    /// AC-002-11 / FR-002-13 "at most 2 imports in flight". Given six screenshots land together and every import is held
    /// at the ingest step; then exactly 2 are running (not 1, not 3) until released, and then all 6 are imported.
    /// Red if: the cap rises to 3 or more (peak 3), drops to 1 (peak 1), or a held file is dropped (finished != 6).
    @Test("AC-002-11 six simultaneous screenshots run at most 2 imports in flight, then all six complete")
    func inFlightCapIsExactlyTwo() async throws {
        // given: pickup running, ingest held shut
        let rig = try PerfPickupRig()
        defer { rig.cleanUp() }
        try await rig.launch(libraryItems: 0)
        rig.ingest.hold()

        // when: six files land at once
        for index in 1...6 { try rig.arrive(named: "Screenshot oc-cap-\(index)-\(UUID().uuidString).png") }
        let reachedTwo = await eventually(timeout: .seconds(10)) { rig.ingest.current == 2 }
        try? await Task.sleep(for: .milliseconds(1_500))

        // then: the ceiling held at exactly 2 while the rest waited
        #expect(reachedTwo, "two imports run in parallel")
        #expect(rig.ingest.current == 2, "still exactly 2 in flight while the others queue; saw \(rig.ingest.current)")
        #expect(rig.ingest.peak == 2, "never more than 2 at once; peak \(rig.ingest.peak)")
        #expect(rig.ingest.finished == 0, "nothing finished while held")

        // and: released, the queue drains and all six are stored
        rig.ingest.release()
        let drained = await eventually(timeout: .seconds(15)) { rig.ingest.finished == 6 }
        #expect(drained, "all six imports complete after release; finished \(rig.ingest.finished)")
        #expect(await rig.libraryCount() == 6, "six items, each file once")
        #expect(rig.ingest.peak == 2, "the ceiling held through the drain; peak \(rig.ingest.peak)")
    }

    /// OC-2068 (FR-002-14). Given pickup on, Active, folder resolved, no screenshots; when Flotsam idles 10 minutes; then
    /// pickup adds no measurable CPU. Asserted as its causes: over 1,200 shared 0.5 s ticks (10 min) the watcher runs
    /// its own work only on the 30 s tick (20 times, nothing between), reads no file, sleeps never, and opens no
    /// second watch.
    /// Red if: the watcher adds its own timer or sleep loop, does work on every 0.5 s tick instead of every 30 s one (the
    /// 10-minute total stops being 20 x one tick), reads a file while idle, or re-creates the watch.
    @Test("OC-2068 ten idle minutes: work only on the 30 s tick, no file reads, no sleeping, one watch")
    func idlePickupDoesNoWorkBetweenThirtySecondTicks() async throws {
        // given: pickup running on a manual clock, the folder empty, the calm after launch reached
        let clock = PerfManualClock()
        let rig = try PerfPickupRig(clock: clock)
        defer { rig.cleanUp() }
        try await rig.launch(libraryItems: 0)
        #expect(rig.pollTick.registrationCount == 1, "the watcher holds exactly one registration on the shared tick (ADR-0004)")
        #expect(rig.source.startCount == 1, "one watch started")

        // calibration: one 30 s tick's worth of the shared 0.5 s ticks is one unit of watcher work. The watcher drops a
        // tick that fires while the previous one is unfinished, so every shared tick is given 5 ms to finish whatever it
        // started: a watcher that works on each 0.5 s tick then does 60 units per 30 s, never one (a fire storm would let
        // the drop-guard hide the extra work).
        func thirtySeconds() async {
            for _ in 0..<60 {
                clock.advance(by: PollTick.interval)
                rig.pollTick.fire()
                try? await Task.sleep(for: .milliseconds(5))
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        func delta(_ after: [String: Int], _ before: [String: Int]) -> [String: Int] {
            after.reduce(into: [:]) { result, entry in
                let difference = entry.value - before[entry.key, default: 0]
                if difference != 0 { result[entry.key] = difference }
            }
        }
        let calibrationStart = rig.fileSystem.snapshot
        await thirtySeconds()
        let perTick = delta(rig.fileSystem.snapshot, calibrationStart)
        // Thirty seconds of shared ticks re-resolve the folder exactly once (FR-002-14: "the 30 s re-resolution"). This
        // literal anchors the cadence, so a watcher that works on every 0.5 s tick cannot hide behind its own calibration.
        #expect(perTick["contentsOfDirectory"] == 1, "30 s of ticks list the watched folder once; saw \(perTick)")
        #expect(perTick["fileInfo"] == 1, "and stat it once; saw \(perTick)")

        // when: 10 minutes pass (1,200 ticks of 0.5 s = 20 thirty-second ticks)
        let before = rig.fileSystem.snapshot
        for _ in 0..<20 { await thirtySeconds() }
        let idle = delta(rig.fileSystem.snapshot, before)

        // then: 20 ticks of exactly the calibrated work and nothing else
        let expected = perTick.mapValues { $0 * 20 }
        #expect(idle == expected, "10 idle minutes did \(idle), expected 20 x the one-tick work \(perTick)")
        // The re-resolution stats and lists the watched folder (that is FR-002-14's 30 s check); no file's content or
        // attributes are read, because there is no file.
        #expect(idle["readFile", default: 0] + idle["readFileNoFollow", default: 0] + idle["extendedAttribute", default: 0] == 0,
                "no screenshots, so no file is read while idle")
        #expect(clock.sleepCount == 0, "idle pickup never sleeps on a timer of its own (event-driven)")
        #expect(rig.source.startCount == 1, "the watch is not re-created while idle")
        #expect(rig.pollTick.registrationCount == 1, "still one registration, nothing added")
        #expect(rig.ingest.finished == 0, "no screenshots, nothing ingested")
    }
}

/// Tasks spawned in a loop, read back after it.
private final class Handoffs: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Double?, Never>] = []
    func add(_ task: Task<Double?, Never>) { lock.withLock { tasks.append(task) } }
    var all: [Task<Double?, Never>] { lock.withLock { tasks } }
}
