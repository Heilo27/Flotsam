import Foundation
import os
import Testing
@testable import FlotsamBase

// TASK-379: kills for the FRD-000 logging mutants that survived the TASK-369 census (X265, X271-X277, X280-X286, X288,
// X294, X297, X308, X309, X310). Every expected value is a literal; nothing recomputes production's expression (B2).
// Contracts: FR-000-09 (subsystem, categories, levels, `#if DEBUG` trace), FR-000-10 (log privacy), FR-000-12 (signposts).

// MARK: - OC-0073 / OC-0036: bundle identifier character set (X265)

@Suite(.timeLimit(.minutes(1))) struct LogIdentifierCharacterSetTests {
    /// OC-0073 (identifier shape feeding OC-0036). given a bundle identifier containing one punctuation or symbol
    /// character that is not a letter, digit or hyphen, then construction fails. Turns red if the allowed set gains
    /// that character (X265 adds `~`).
    @Test("OC-0073 a bundle identifier with a character outside letters, digits and hyphen is rejected", arguments: [
        "~", "_", "+", "=", "!", "#", "$", "%", "^", "&", "*", "(", ")", "[", "]", "{", "}", "|", "\\", ";", ":", "'",
        "\"", ",", "<", ">", "/", "?", "`", " ", "@", "\t", "é",
    ])
    func rejectedCharacter(character: String) {
        #expect(BundleIdentifier("com.ex\(character)ample.app") == nil, "\(character.debugDescription) in a label")
        #expect(BundleIdentifier("\(character)com.example") == nil, "\(character.debugDescription) leading")
    }

    /// OC-0073 boundary. given every letter, digit and hyphen, then they are accepted, so the rejection above is the
    /// set's edge and not a blanket refusal.
    @Test("OC-0073 every letter, digit and hyphen is accepted in a label")
    func acceptedCharacters() {
        let all = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
        #expect(all.count == 63)
        #expect(BundleIdentifier("com.\(all)")?.value == "com.\(all)")
        #expect(BundleIdentifier("a.b-c.D9")?.value == "a.b-c.D9")
    }
}

// MARK: - OC-0036 / OC-0071 / OC-0072: the closed system-declared list (X271-X277, X280-X286, X288)

@Suite(.timeLimit(.minutes(1))) struct SystemDeclaredUTITests {
    /// The FR-000-10 list, as literals. Twenty entries; adding or removing one is a deliberate change that edits this
    /// list and the production list in the same commit.
    static let closedList: [String] = [
        "public.utf8-plain-text", "public.utf16-plain-text", "public.utf16-external-plain-text", "public.plain-text",
        "public.text", "public.html", "public.rtf", "public.url", "public.file-url", "public.png", "public.tiff",
        "public.jpeg", "public.heic", "public.image", "public.data", "public.vcard", "public.folder",
        "com.apple.rtfd", "com.adobe.pdf", "NSStringPboardType",
    ]

    /// OC-0072. given each system-declared identifier, then it is public (rendered in the clear, nothing private).
    /// Turns red if any one string in the production list is altered (X271-X277, X280-X286, X288).
    @Test("OC-0072 each system-declared identifier logs public", arguments: SystemDeclaredUTITests.closedList)
    func systemDeclaredIsPublic(identifier: String) {
        #expect(LogSafeValue.uti(PasteboardTypeID(identifier)).isPublic, "\(identifier)")
        let rendered = FlotsamLog.render([.uti: .uti(PasteboardTypeID(identifier))])
        #expect(rendered.publicPart == "uti=\(identifier)")
        #expect(rendered.privatePart == "")
    }

    /// OC-0072 near miss. given each system-declared identifier with a character appended, prepended or its last
    /// character dropped, then it is private. Turns red if the list matches by prefix or the entry itself gains
    /// the suffix.
    @Test("OC-0072 a near miss of each system-declared identifier logs private", arguments: SystemDeclaredUTITests.closedList)
    func nearMissIsPrivate(identifier: String) {
        for variant in ["\(identifier)~", "~\(identifier)", String(identifier.dropLast()), "\(identifier) "] {
            let rendered = FlotsamLog.render([.uti: .uti(PasteboardTypeID(variant))])
            #expect(rendered.publicPart == "", "\(variant.debugDescription)")
            #expect(rendered.privatePart == "uti=\(variant)", "\(variant.debugDescription)")
        }
    }

    /// OC-0072 closed list. given the production set, then it has exactly the twenty literals above: no extra
    /// identifier was added without a test, none was dropped.
    @Test("OC-0072 the production list is exactly the twenty documented identifiers")
    func listIsClosed() {
        #expect(SystemDeclaredUTITests.closedList.count == 20)
        #expect(Set(SystemDeclaredUTITests.closedList).count == 20)
        #expect(PasteboardTypeID.systemDeclared == Set(SystemDeclaredUTITests.closedList))
    }
}

// MARK: - OC-0036: private text of a record (X294)

@Suite(.timeLimit(.minutes(1))) struct LogRecordPrivateTextTests {
    private func record(message: String?, cause: UnderlyingErrorInfo?) -> LogRecord {
        LogRecord(
            category: .storage, level: .error, headline: "STO-IO-001 error", publicContext: "count=3",
            privateContext: "itemId=6F9619FF-8B86-D011-B42D-00C04FC964FF", message: message, cause: cause
        )
    }

    /// OC-0036. given a record with a cause and no message, then the cause's domain and code are in the private text
    /// (redacted in release). Turns red if the cause is dropped when the message is nil (X294).
    @Test("OC-0036 privateText keeps the cause when there is no message")
    func causeOnly() {
        let text = record(message: nil, cause: UnderlyingErrorInfo(domain: "NSCocoaErrorDomain", code: 640)).privateText
        #expect(text == "itemId=6F9619FF-8B86-D011-B42D-00C04FC964FF  NSCocoaErrorDomain:640")
    }

    /// OC-0036. given a record with neither message nor cause, then the private text is exactly the private context
    /// (no trailing separators). Turns red if the guard falls through for the empty case.
    @Test("OC-0036 privateText is the bare private context when there is no message and no cause")
    func neither() {
        #expect(record(message: nil, cause: nil).privateText == "itemId=6F9619FF-8B86-D011-B42D-00C04FC964FF")
    }

    /// OC-0036. given a message and no cause, then the message follows the private context.
    @Test("OC-0036 privateText carries the message when there is no cause")
    func messageOnly() {
        #expect(record(message: "disk full", cause: nil).privateText == "itemId=6F9619FF-8B86-D011-B42D-00C04FC964FF disk full ")
    }

    /// OC-0036. given both, then message and cause both follow the private context, and neither is in publicText.
    @Test("OC-0036 privateText carries message and cause; publicText carries neither")
    func both() {
        let value = record(message: "disk full", cause: UnderlyingErrorInfo(domain: "NSPOSIXErrorDomain", code: 28))
        #expect(value.privateText == "itemId=6F9619FF-8B86-D011-B42D-00C04FC964FF disk full NSPOSIXErrorDomain:28")
        #expect(value.publicText == "STO-IO-001 error count=3")
    }
}

// MARK: - FR-000-09: subsystem (X297) and trace headline (X308)

@Suite(.timeLimit(.minutes(1))) struct LogSubsystemAndTraceTests {
    /// OC-0034 (FR-000-09). given the package fallback, then it is the app's reverse-DNS identifier. Turns red if the
    /// constant changes (X297), which would split `swift test` logs from the app's subsystem.
    @Test("OC-0034 the fallback subsystem is io.github.heilo27.Flotsam")
    func fallbackConstant() {
        #expect(FlotsamLog.fallbackSubsystem == "io.github.heilo27.Flotsam")
    }

    /// OC-0034. given no host bundle identifier (a bare test runner), then the effective subsystem is the fallback
    /// literal; given one, it is that identifier.
    @Test("OC-0034 subsystem is the host bundle identifier, else the fallback")
    func effectiveSubsystem() {
        if let host = Bundle.main.bundleIdentifier {
            #expect(FlotsamLog.subsystem == host)
        } else {
            #expect(FlotsamLog.subsystem == "io.github.heilo27.Flotsam")
        }
    }

    /// OC-0034 (FR-000-09 trace). given a trace call in a debug build, then one record is written at `.debug`,
    /// headline `trace`, the given category, the message private and the allowlisted context public. In a release
    /// build the call writes nothing. Turns red if the headline changes (X308).
    @Test("OC-0034 a trace is one .debug record headed `trace`; compiled out of release")
    func traceRecord() throws {
        let sink = RecordingLogSink()
        let bundle = try #require(BundleIdentifier("com.flotsamtest.tracebid"))
        FlotsamLog.trace("opening store", category: .storage, context: [.count: .int(2), .bundleId: .bundleId(bundle)], sink: sink)
        #if DEBUG
        #expect(sink.records.count == 1)
        let record = try #require(sink.records.first)
        #expect(record.headline == "trace")
        #expect(record.level.rawValue == 2)
        #expect(record.category == .storage)
        #expect(record.publicText == "trace count=2")
        #expect(record.privateText == "bundleId=com.flotsamtest.tracebid opening store ")
        #else
        #expect(sink.records.isEmpty)
        #endif
    }

    /// OC-0034. given a trace with no category, then it logs under `core`.
    @Test("OC-0034 a trace defaults to the core category")
    func traceDefaultCategory() {
        let sink = RecordingLogSink()
        FlotsamLog.trace("x", sink: sink)
        #if DEBUG
        #expect(sink.records.map(\.category) == [.core])
        #expect(sink.records.map(\.headline) == ["trace"])
        #else
        #expect(sink.records.isEmpty)
        #endif
    }
}

// MARK: - FR-000-12: signposts (X309, X310)

/// Reads real signposts the way Instruments does. `OSLogStore` cannot return signposts and `OSSignposter` has no
/// readback, so a short-lived `log stream --signpost` (an unprivileged system tool, no production seam) filtered to
/// this process, the app subsystem and category `perf` is the observer.
private final class SignpostProbe: @unchecked Sendable {
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

    func events() -> [Event] {
        guard let text = try? String(contentsOf: outputURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("{"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = object["signpostName"] as? String, let type = object["signpostType"] as? String,
                  let category = object["category"] as? String else { return nil }
            return Event(name: name, type: type, category: category)
        }
    }

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

@Suite(.serialized, .timeLimit(.minutes(1))) struct SignpostTests {
    static let names = [
        "capture.persist", "library.open", "library.search", "paste.back", "shelf.reveal", "retention.sweep", "trigger.expand",
        "retention.clearHistory",
    ]

    /// OC-0041 / OC-0042. given a begin and an end of each of the eight intervals, then the system sees, for each
    /// literal name, exactly one begin and exactly one end, all in category `perf`. Turns red if `end()` stops ending
    /// the interval (X309: no end events) or the category changes (X310: events under another category).
    @Test("OC-0041 OC-0042 each interval emits one begin and one end under category perf")
    func beginEndPerInterval() async throws {
        let probe = SignpostProbe()
        do {
            try await probe.start()
            for interval in PerfInterval.allCases { Signposts.begin(interval).end() }
            let events = try await probe.collect(atLeast: 16)
            await probe.stop()
            #expect(PerfInterval.allCases.map(\.rawValue) == SignpostTests.names)
            #expect(events.count == 16, "\(events)")
            #expect(Set(events.map(\.category)) == ["perf"])
            for name in SignpostTests.names {
                #expect(events.filter { $0.name == name && $0.type == "begin" }.count == 1, "begin \(name)")
                #expect(events.filter { $0.name == name && $0.type == "end" }.count == 1, "end \(name)")
            }
        } catch {
            await probe.stop()
            throw error
        }
    }

    /// OC-0041. given `measure` around a body, then the body's result is returned and the interval has one begin and
    /// one end, the begin first. Turns red if `measure` leaves the lane open (X309 via `defer { span.end() }`).
    @Test("OC-0041 measure returns the result and closes its interval exactly once")
    func measureClosesInterval() async throws {
        let probe = SignpostProbe()
        do {
            try await probe.start()
            let result = Signposts.measure(.librarySearch) { 6 * 7 }
            let events = try await probe.collect(atLeast: 2)
            await probe.stop()
            #expect(result == 42)
            #expect(events == [
                SignpostProbe.Event(name: "library.search", type: "begin", category: "perf"),
                SignpostProbe.Event(name: "library.search", type: "end", category: "perf"),
            ])
        } catch {
            await probe.stop()
            throw error
        }
    }
}
