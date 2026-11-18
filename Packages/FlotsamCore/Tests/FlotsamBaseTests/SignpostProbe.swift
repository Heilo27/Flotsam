import Foundation
import os
@testable import FlotsamBase

/// Reads real signposts the way Instruments does. `OSLogStore` cannot return signposts and `OSSignposter` has no
/// readback, so a short-lived `log stream --signpost` (an unprivileged system tool, no production seam) filtered to
/// this process, the app subsystem and category `perf` is the observer.
final class SignpostProbe: @unchecked Sendable {
    struct Event: Equatable { let name: String; let type: String; let category: String }

    private var process = Process()
    private let outputURL: URL
    private let pidFileURL: URL
    private var started = false

    init() {
        let unique = UUID().uuidString
        outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-signpost-\(unique).ndjson")
        pidFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-signpost-\(unique).pid")
    }

    /// The pid of the `log stream` child (read from the launcher's pid file), or nil before it has been written.
    var childPID: Int32? {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Last-resort cleanup for a probe that is dropped without `stop()` (a throw or an early return that skipped it).
    deinit {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// Runs `executable` under a small `sh` launcher that ends it when `parentPID` is no longer alive, so the child cannot
    /// outlive the process that started it (TASK-481: a `log stream` whose test process was killed or timed out was
    /// reparented to launchd and ran for days). `stop()` and `deinit` cover the orderly paths; this covers the process
    /// being killed outright, which no Swift code gets to react to. The child's pid is written to `pidFile`. SIGTERM to
    /// the launcher ends the child too.
    static func launch(parentPID: Int32, executable: String, arguments: [String], pidFile: URL) -> Process {
        let script = """
        parent=$1; pidfile=$2; shift 2
        "$@" &
        child=$!
        echo "$child" > "$pidfile"
        ( while kill -0 "$parent" 2>/dev/null; do sleep 1; done; kill "$child" 2>/dev/null ) &
        watcher=$!
        trap 'kill "$child" "$watcher" 2>/dev/null' TERM INT
        wait "$child"
        kill "$watcher" 2>/dev/null
        """
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", script, "sh", String(parentPID), pidFile.path, executable] + arguments
        return launcher
    }

    /// Starts the stream and returns once it reports it is filtering. The predicate names the subsystem but NOT the
    /// category, so a signposter on a wrong category is visible as an event with the wrong category (not silence).
    func start() async throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let sink = try FileHandle(forWritingTo: outputURL)
        process = Self.launch(
            parentPID: ProcessInfo.processInfo.processIdentifier, executable: "/usr/bin/log",
            arguments: [
                "stream", "--signpost", "--style", "ndjson",
                "--predicate", "subsystem == \"\(FlotsamLog.subsystem)\" AND processID == \(ProcessInfo.processInfo.processIdentifier)",
            ],
            pidFile: pidFileURL)
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        started = true
        for _ in 0..<100 {
            if (try? String(contentsOf: outputURL, encoding: .utf8))?.contains("Filtering the log data") == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // "Filtering the log data" is printed before the stream is attached to the live feed, and `log stream` does not
        // replay: a signpost emitted in that gap is lost, which under host load turned into an empty capture (TASK-481).
        // So instead of a fixed pause, emit a beacon until the stream hands one back; seeing any beacon proves attachment.
        let beacon = OSSignposter(subsystem: FlotsamLog.subsystem, category: Self.beaconCategory)
        let began = Date()
        for _ in 0..<300 where !beaconSeen {
            beacon.emitEvent("probe.ready")
            try await Task.sleep(for: .milliseconds(100))
            _ = marks()
        }
        readyAfterMs = Int(Date().timeIntervalSince(began) * 1000)
        guard beaconSeen else { throw ProbeError.streamNeverAttached }
    }

    enum ProbeError: Error { case streamNeverAttached }
    /// Category of the readiness beacon; it is consumed by the probe and never appears in `marks()`.
    static let beaconCategory = "probe-ready"
    /// True once the stream has delivered one of this probe's beacons, which proves it is attached to the live feed.
    private(set) var beaconSeen = false
    /// How long attachment took, for a test to see how much margin the old fixed pause had.
    private(set) var readyAfterMs = 0

    /// An event with what pairs it to its other half (`id`) and places it in time (`at`), for a test that shares its
    /// process with other tests emitting the same interval and so has to look only at its own window.
    struct Mark { let event: Event; let id: Int; let at: Date }

    private static let timestampFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return format
    }()

    private let lock = NSLock()
    private var readOffset: UInt64 = 0
    private var partialLine = Data()
    private var seen: [Mark] = []

    /// Every signpost seen so far. Reads only what the stream has appended since the last call: in a process that
    /// logs a lot the file grows to many megabytes (the stream carries ordinary log lines too), and re-parsing all of
    /// it on every 100 ms poll starved the wait past the test time limit.
    func marks() -> [Mark] {
        lock.lock()
        defer { lock.unlock() }
        guard let reader = try? FileHandle(forReadingFrom: outputURL) else { return seen }
        defer { try? reader.close() }
        guard (try? reader.seek(toOffset: readOffset)) != nil, let chunk = try? reader.readToEnd(), !chunk.isEmpty else { return seen }
        readOffset += UInt64(chunk.count)
        var lines = (partialLine + chunk).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Data($0) }
        partialLine = lines.removeLast()
        for line in lines {
            guard line.first == UInt8(ascii: "{"), line.range(of: Data("\"signpostName\"".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            // Checked before the id is read: an event's exclusive id does not fit in an Int, so the cast below would skip it.
            if object["category"] as? String == Self.beaconCategory { beaconSeen = true; continue }
            guard let name = object["signpostName"] as? String, let type = object["signpostType"] as? String,
                  let category = object["category"] as? String, let id = object["signpostID"] as? Int,
                  let stamp = object["timestamp"] as? String, let at = Self.timestampFormat.date(from: stamp) else { continue }
            seen.append(Mark(event: Event(name: name, type: type, category: category), id: id, at: at))
        }
        return seen
    }

    func events() -> [Event] { marks().map(\.event) }

    /// Waits until at least `count` events have been seen (up to 20 s), then a further settle window so an unexpected
    /// extra event has time to show up.
    func collect(atLeast count: Int) async throws -> [Event] {
        for _ in 0..<200 where events().count < count { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .seconds(1.5))
        return events()
    }

    func stop() async {
        guard started else { return }
        if process.isRunning { process.terminate() }
        for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: pidFileURL)
    }
}
