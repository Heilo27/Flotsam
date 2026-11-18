import Foundation
@testable import FlotsamBase

/// Reads real signposts the way Instruments does. `OSLogStore` cannot return signposts and `OSSignposter` has no
/// readback, so a short-lived `log stream --signpost` (an unprivileged system tool, no production seam) filtered to
/// this process, the app subsystem and category `perf` is the observer.
final class SignpostProbe: @unchecked Sendable {
    struct Event: Equatable { let name: String; let type: String; let category: String }

    private let process = Process()
    private let outputURL: URL
    private var started = false

    init() {
        outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-signpost-\(UUID().uuidString).ndjson")
    }

    /// Starts the stream and returns once it reports it is filtering. The predicate names the subsystem but NOT the
    /// category, so a signposter on a wrong category is visible as an event with the wrong category (not silence).
    func start() async throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let sink = try FileHandle(forWritingTo: outputURL)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--signpost", "--style", "ndjson",
            "--predicate", "subsystem == \"\(FlotsamLog.subsystem)\" AND processID == \(ProcessInfo.processInfo.processIdentifier)",
        ]
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        started = true
        for _ in 0..<100 {
            if (try? String(contentsOf: outputURL, encoding: .utf8))?.contains("Filtering the log data") == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(800))
    }

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
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let name = object["signpostName"] as? String, let type = object["signpostType"] as? String,
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
    }
}
