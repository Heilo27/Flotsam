import Foundation
import Testing
@testable import FlotsamBase

// Phase 8A adversarial probes for FRD-000. Written blind (the existing suite was not opened) to break the
// implementation. Each red test names the ticket that tracks the defect; see the tag on every test.
//
// Expected values are literals only (TEST-DOCTRINE B2). Probes that found nothing and guard a real boundary are kept.

private let advFallbackText = "Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings › About."
private let advCapPrmText = "macOS is blocking Flotsam from reading copied items. Allow Flotsam under Paste from Other Apps in System Settings."
private let advCapOsText = "Flotsam couldn't read the clipboard just now. It will keep trying."
private let advSspPrmText = "Flotsam can't read your screenshot folder. Allow access in System Settings › Privacy & Security › Files and Folders."
private let advSspIoText = "Your screenshot folder isn't available, so Flotsam is watching the Desktop instead."

// MARK: - Doubles

private final class AdvClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ seconds: TimeInterval) { current = Date(timeIntervalSince1970: seconds) }
    func now() -> Date { lock.withLock { current } }
    func set(_ seconds: TimeInterval) { lock.withLock { current = Date(timeIntervalSince1970: seconds) } }
    func sleep(for duration: Duration) async {}
}

@MainActor
private final class AdvPresenter: ErrorPresenter {
    var huds: [String] = []
    var noticeLists: [[Notice]] = []
    var fatals: [ErrorCode] = []
    func showHUD(message: String) { huds.append(message) }
    func noticesChanged(_ notices: [Notice]) { noticeLists.append(notices) }
    func presentFatal(_ error: FlotsamError) { fatals.append(error.code) }
}

private final class AdvSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LogRecord] = []
    func write(_ record: LogRecord) { lock.withLock { stored.append(record) } }
    var records: [LogRecord] { lock.withLock { stored } }
}

@MainActor
private func advMakeReporter(clock: AdvClock) -> (ErrorReporter, AdvPresenter, AdvSink) {
    let presenter = AdvPresenter()
    let sink = AdvSink()
    return (ErrorReporter(presenter: presenter, clock: clock, sink: sink), presenter, sink)
}

// MARK: - Throttle (FR-000-08)

@Suite("8A FRD-000 throttle")
@MainActor
struct Adversarial000ThrottleTests {
    // OC: FR-000-08 boundary. Mutation: `< window` becomes `<= window` (or the reverse) turns one of these red.
    @Test("same code is suppressed at 59.999 s and admitted at exactly 60 s")
    func sixtySecondBoundary() async {
        // given a HUD for CAP-PRM-001 at t=1000
        let clock = AdvClock(1000)
        let (reporter, presenter, _) = advMakeReporter(clock: clock)
        await reporter.report(FlotsamError(.capPrm001, "a"), origin: .userInitiated)
        // when the same code returns 59.999 s later, then 60 s after the first
        clock.set(1059.999)
        await reporter.report(FlotsamError(.capPrm001, "a"), origin: .userInitiated)
        let afterJustUnder = presenter.huds.count
        clock.set(1060)
        await reporter.report(FlotsamError(.capPrm001, "a"), origin: .userInitiated)
        // then 59.999 s adds nothing and 60 s surfaces again
        #expect(afterJustUnder == 1)
        #expect(presenter.huds == [advCapPrmText, advCapPrmText])
    }

    // OC: FR-000-08 flood guard. Mutation: maxHUDsPerWindow 3 -> 4 turns red.
    @Test("four distinct codes at one instant surface exactly three HUDs and drop the fourth")
    func hudFloodCap() async {
        let clock = AdvClock(1000)
        let (reporter, presenter, _) = advMakeReporter(clock: clock)
        await reporter.report(FlotsamError(.capPrm001, "a"), origin: .userInitiated)
        await reporter.report(FlotsamError(.capOs001, "a"), origin: .userInitiated)
        await reporter.report(FlotsamError(.sspPrm001, "a"), origin: .userInitiated)
        await reporter.report(FlotsamError(.sspIo001, "a"), origin: .userInitiated)
        #expect(presenter.huds == [advCapPrmText, advCapOsText, advSspPrmText])
        #expect(!presenter.huds.contains(advSspIoText))
    }

    // OC: FR-000-08 flood guard window. The fourth code must surface once the first three age out.
    @Test("the HUD cap releases after 60 s")
    func hudCapReleases() async {
        let clock = AdvClock(1000)
        let (reporter, presenter, _) = advMakeReporter(clock: clock)
        await reporter.report(FlotsamError(.capPrm001, "a"), origin: .userInitiated)
        await reporter.report(FlotsamError(.capOs001, "a"), origin: .userInitiated)
        await reporter.report(FlotsamError(.sspPrm001, "a"), origin: .userInitiated)
        clock.set(1060)
        await reporter.report(FlotsamError(.sspIo001, "a"), origin: .userInitiated)
        #expect(presenter.huds.count == 4)
        #expect(presenter.huds.last == advSspIoText)
    }

    // OC: FR-000-08. 8A break, ticket TASK-348. Wall clock steps backward 10 000 s (NTP, manual change, resume).
    // Mutation that turns it green: discard stored timestamps that are ahead of `now`.
    @Test("same code surfaces again 61 s after a backward clock jump (FR-000-08, TASK-348)")
    func backwardJumpSameCode() async {
        // given a HUD at t=10000 and then the clock stepping back to t=0
        let clock = AdvClock(10_000)
        let (reporter, presenter, _) = advMakeReporter(clock: clock)
        await reporter.report(FlotsamError(.capPrm001, "a"), origin: .userInitiated)
        clock.set(0)
        // when the same code is raised 61 s of new clock time later
        clock.set(61)
        await reporter.report(FlotsamError(.capPrm001, "a"), origin: .userInitiated)
        // then the user is told again (the throttle window is 60 s)
        #expect(presenter.huds == [advCapPrmText, advCapPrmText])
    }

    // OC: FR-000-08. 8A break, ticket TASK-348. HUD starvation: three HUDs pinned in the future block every code.
    @Test("a fourth distinct code surfaces 61 s after a backward jump past three recent HUDs (FR-000-08, TASK-348)")
    func backwardJumpHudStarvation() async {
        let clock = AdvClock(10_000)
        let (reporter, presenter, _) = advMakeReporter(clock: clock)
        await reporter.report(FlotsamError(.capPrm001, "a"), origin: .userInitiated)
        await reporter.report(FlotsamError(.capOs001, "a"), origin: .userInitiated)
        await reporter.report(FlotsamError(.sspPrm001, "a"), origin: .userInitiated)
        clock.set(61)
        await reporter.report(FlotsamError(.sspIo001, "a"), origin: .userInitiated)
        #expect(presenter.huds.count == 4)
        #expect(presenter.huds.last == advSspIoText)
    }

    // OC: FR-000-08. A jump must not open a flood: after the fix, 4 distinct codes at the post-jump instant still cap at 3.
    @Test("flood guard still caps at three HUDs after a backward jump")
    func floodGuardAfterJump() async {
        let clock = AdvClock(10_000)
        let (reporter, presenter, _) = advMakeReporter(clock: clock)
        clock.set(0)
        await reporter.report(FlotsamError(.capPrm001, "a"), origin: .userInitiated)
        await reporter.report(FlotsamError(.capOs001, "a"), origin: .userInitiated)
        await reporter.report(FlotsamError(.sspPrm001, "a"), origin: .userInitiated)
        await reporter.report(FlotsamError(.sspIo001, "a"), origin: .userInitiated)
        #expect(presenter.huds.count == 3)
    }

    // OC: FR-000-08 suppressed occurrences leave no trace. A fault every 20 s must surface at t=0 and t=60, not never.
    @Test("a code firing every 20 s surfaces at 0 s and 60 s only")
    func suppressedOccurrenceDoesNotResetTimer() async {
        let clock = AdvClock(1000)
        let (reporter, presenter, _) = advMakeReporter(clock: clock)
        for step in 0...3 {
            clock.set(1000 + TimeInterval(step) * 20)
            await reporter.report(FlotsamError(.capPrm001, "a"), origin: .userInitiated)
        }
        #expect(presenter.huds.count == 2)
    }

    // OC: FR-000-08 / AC-000-04. Concurrent raises from many tasks across severities: nothing lost, nothing doubled.
    @Test("200 concurrent reports across severities: ring holds the newest 100, HUD cap holds, fatal always presented")
    func concurrentReports() async {
        let clock = AdvClock(5000)
        let (reporter, presenter, sink) = advMakeReporter(clock: clock)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    switch index % 4 {
                    case 0: await reporter.report(FlotsamError(.capPol001, "i"), origin: .background)
                    case 1: await reporter.report(FlotsamError(.capPrm001, "w"), origin: .userInitiated)
                    case 2: await reporter.report(FlotsamError(.libOs001, "e"), origin: .background)
                    default: await reporter.report(FlotsamError(.stoDb003, "f"), origin: .userInitiated)
                    }
                }
            }
        }
        let ring = await reporter.recentErrors()
        // Info (50) is logged, never recorded; the other 150 raises are recorded, capped at 100.
        #expect(sink.records.count == 200)
        #expect(ring.count == 100)
        #expect(!ring.contains { $0.severity == .info })
        #expect(presenter.fatals.count == 50)
        #expect(presenter.huds.count == 1)
        #expect(presenter.noticeLists.last?.count == 1)
    }
}

// MARK: - Ring buffer and notice board (FR-000-08, FR-000-13)

@Suite("8A FRD-000 ring and notices")
@MainActor
struct Adversarial000RingTests {
    // OC: FR-000-13 capacity. Mutation: `>` becomes `>=`, or capacity 100 -> 101, turns it red.
    @Test("ring holds exactly 100, then drops only the oldest on the 101st")
    func ringCapacityBoundary() {
        var ring = ErrorRingBuffer()
        for index in 0..<100 {
            ring.record(RaisedError(code: .libOs001, severity: .error, timestamp: Date(timeIntervalSince1970: TimeInterval(index))))
        }
        #expect(ring.entries.count == 100)
        #expect(ring.entries.first?.timestamp == Date(timeIntervalSince1970: 0))
        ring.record(RaisedError(code: .libOs001, severity: .error, timestamp: Date(timeIntervalSince1970: 100)))
        #expect(ring.entries.count == 100)
        #expect(ring.entries.first?.timestamp == Date(timeIntervalSince1970: 1))
        #expect(ring.entries.last?.timestamp == Date(timeIntervalSince1970: 100))
    }

    // OC: FR-000-08 b. 11 distinct background codes: list keeps the newest 10, newest first, oldest gone.
    @Test("eleventh background notice evicts the oldest and sits first")
    func noticeCapacity() async {
        let clock = AdvClock(1000)
        let (reporter, presenter, _) = advMakeReporter(clock: clock)
        let codes: [ErrorCode] = [
            .capPrm001, .capOs001, .capLim001, .capLim003, .sspPrm001, .sspIo001, .sspIo003, .sspLim001,
            .sspOs001, .libDat001, .trgVal005,
        ]
        for code in codes { await reporter.report(FlotsamError(code, "n"), origin: .background) }
        let last = presenter.noticeLists.last ?? []
        #expect(last.count == 10)
        #expect(last.first?.code == .trgVal005)
        #expect(last.last?.code == .capOs001)
        #expect(!last.contains { $0.code == .capPrm001 })
    }

    // OC: FR-000-08 b. Dismiss then raise: the list restarts at one, it does not resurrect the dismissed notices.
    @Test("dismissAll clears the list and later notices start from empty")
    func dismissAllThenReport() async {
        let clock = AdvClock(1000)
        let (reporter, presenter, _) = advMakeReporter(clock: clock)
        await reporter.report(FlotsamError(.capPrm001, "n"), origin: .background)
        await reporter.report(FlotsamError(.capOs001, "n"), origin: .background)
        await reporter.dismissAllNotices()
        #expect(presenter.noticeLists.last?.isEmpty == true)
        await reporter.report(FlotsamError(.sspPrm001, "n"), origin: .background)
        #expect(presenter.noticeLists.last?.map(\.code) == [.sspPrm001])
    }

    // OC: FR-000-08 b. Racing dismiss against raises must leave the presenter consistent with the actor's board.
    @Test("dismissAll racing background reports ends with a list the presenter last saw")
    func dismissRacing() async {
        let clock = AdvClock(1000)
        let (reporter, presenter, _) = advMakeReporter(clock: clock)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await reporter.report(FlotsamError(.capPrm001, "n"), origin: .background) }
            group.addTask { await reporter.dismissAllNotices() }
            group.addTask { await reporter.report(FlotsamError(.capOs001, "n"), origin: .background) }
        }
        // every notice list the presenter saw is a prefix-consistent state: never more than the 2 raised
        #expect(presenter.noticeLists.count == 3)
        #expect(presenter.noticeLists.allSatisfy { $0.count <= 2 })
        await reporter.dismissAllNotices()
        #expect(presenter.noticeLists.last?.isEmpty == true)
    }
}

// MARK: - Strings (FR-000-05, FR-000-06)

@Suite("8A FRD-000 strings")
struct Adversarial000StringsTests {
    // OC: FR-000-05. 8A break, ticket TASK-347. %@ template handed an Int argument crashed the process (SIGSEGV).
    @Test("a count handed to a %@ template returns the fallback, never crashes (FR-000-05, TASK-347)")
    func countIntoStringPlaceholder() {
        #expect(FlotsamStrings.message(for: .capLim001, arguments: [.count(5)]) == advFallbackText)
    }

    // OC: FR-000-05. 8A break, ticket TASK-347. Same crash through the reporter path (context .count on a %@ code).
    @Test("a context count on a %@ code returns the fallback, never crashes (FR-000-05, TASK-347)")
    func contextCountIntoStringPlaceholder() {
        let error = FlotsamError(.capLim001, "x", context: [.count: .int(5)])
        #expect(FlotsamStrings.message(for: error) == advFallbackText)
    }

    // OC: FR-000-05. 8A break, ticket TASK-347. %lld template handed text prints a garbage integer to the user.
    @Test("an app name handed to a %lld template returns the fallback, not a garbage number (FR-000-05, TASK-347)")
    func stringIntoCountPlaceholder() {
        #expect(FlotsamStrings.message(for: .capLim003, arguments: [.appName("Safari")]) == advFallbackText)
    }

    // OC: FR-000-06 (140 characters). 8A break, ticket TASK-347.
    @Test("a 10,000-character app name cannot push a message past 140 characters (FR-000-06, TASK-347)")
    func hugeAppNameStaysWithinBudget() {
        let huge = String(repeating: "A", count: 10_000)
        let message = FlotsamStrings.message(for: .capLim001, arguments: [.appName(huge)])
        #expect(message.count <= 140)
    }

    // OC: FR-000-06. 8A break, ticket TASK-347. A negative size must not read "-1 byte".
    @Test("a negative byte size never renders a minus sign (FR-000-06, TASK-347)")
    func negativeByteSize() {
        let message = FlotsamStrings.message(for: .capLim001, arguments: [.byteSize(-1)])
        #expect(!message.contains("-1"))
    }

    // OC: FR-000-06. 8A break, ticket TASK-347. A zero limit must not read "over Zero KB".
    @Test("a zero byte size never renders 'Zero KB' inside a sentence (FR-000-06, TASK-347)")
    func zeroByteSize() {
        let message = FlotsamStrings.message(for: .capLim001, arguments: [.byteSize(0)])
        #expect(!message.contains("Zero"))
    }

    // OC: FR-000-06. TASK-347. Mutation: dropping `max(0, value)` from the `.count` argument turns this red.
    @Test("a negative count renders as 0, never with a minus sign (FR-000-06, TASK-347)")
    func negativeCount() {
        // given a count of -5 for a %lld template, when rendered, then the user reads 0
        let message = FlotsamStrings.message(for: .capLim003, arguments: [.count(-5)])
        #expect(message == "A copy of 0 files was trimmed to the first 500.")
        // and the boundary one step up is untouched: 0 stays 0, 1 stays 1
        #expect(FlotsamStrings.message(for: .capLim003, arguments: [.count(0)]) == "A copy of 0 files was trimmed to the first 500.")
        #expect(FlotsamStrings.message(for: .capLim003, arguments: [.count(1)]) == "A copy of 1 files was trimmed to the first 500.")
    }

    // OC: FR-000-06. TASK-347. Mutation: dropping `max(0, milliseconds)` from `formatDuration` turns this red.
    @Test("a negative duration renders as 0 seconds, never with a minus sign (FR-000-06, TASK-347)")
    func negativeDuration() {
        let message = FlotsamStrings.message(for: .capLim001, arguments: [.duration(milliseconds: -5_000)])
        #expect(message == "A copy was too large to save (over 0 seconds). It is still on your clipboard.")
        #expect(FlotsamStrings.message(for: .capLim001, arguments: [.duration(milliseconds: 5_000)])
            == "A copy was too large to save (over 5 seconds). It is still on your clipboard.")
    }

    // OC: FR-000-06. TASK-347. Literal expectation for the clamp and the digit zero, beside the weaker contains checks.
    // Mutations: dropping `max(0, bytes)`, or `allowsNonnumericFormatting = false`, turns this red.
    @Test("byte sizes -1, 0 and 1 read as 0 bytes, 0 bytes and 1 byte in digits")
    func byteSizeLiterals() {
        let negative = FlotsamStrings.message(for: .capLim001, arguments: [.byteSize(-1)])
        let zero = FlotsamStrings.message(for: .capLim001, arguments: [.byteSize(0)])
        let one = FlotsamStrings.message(for: .capLim001, arguments: [.byteSize(1)])
        #expect(negative == "A copy was too large to save (over 0 bytes). It is still on your clipboard.")
        #expect(zero == "A copy was too large to save (over 0 bytes). It is still on your clipboard.")
        #expect(one == "A copy was too large to save (over 1 byte). It is still on your clipboard.")
    }

    // OC: FR-000-06. TASK-347. The cut must keep the sentence: ellipsis present, template tail present, exactly 140.
    // Mutation: dropping the truncation loop (or cutting the template instead of the name) turns this red.
    @Test("an over-long app name is cut with an ellipsis and the rest of the sentence survives")
    func truncationKeepsTemplate() {
        let message = FlotsamStrings.message(for: .capLim001, arguments: [.appName(String(repeating: "A", count: 500))])
        #expect(message.count == 140)
        #expect(message.hasPrefix("A copy was too large to save (over AAAA"))
        #expect(message.hasSuffix("\u{2026}). It is still on your clipboard."))
    }

    // OC: FR-000-05 guard. Substituted values are data: %@, {count}, newlines, RTL and emoji must come out verbatim.
    // Mutation: formatting the template twice, or substituting with a replace loop, turns it red.
    @Test("hostile app names are substituted verbatim and never re-interpreted")
    func hostileAppNameVerbatim() {
        let name = "100%@ {count} %lld \n\u{202E}שלום 🙂"
        let message = FlotsamStrings.message(for: .capLim001, arguments: [.appName(name)])
        #expect(message == "A copy was too large to save (over \(name)). It is still on your clipboard.")
    }

    // OC: FR-000-05 guard. Placeholder-count mismatch falls back in both directions, and an empty list on a bare code is the template.
    @Test("argument count mismatch falls back; no placeholders and no arguments returns the template")
    func argumentCountMismatch() {
        #expect(FlotsamStrings.message(for: .capLim001) == advFallbackText)
        #expect(FlotsamStrings.message(for: .capLim001, arguments: [.appName("a"), .appName("b")]) == advFallbackText)
        #expect(FlotsamStrings.message(for: .capOs001) == advCapOsText)
        #expect(FlotsamStrings.message(for: .capOs001, arguments: [.count(1)]) == advFallbackText)
        // an Info code has no catalogue message at all
        #expect(FlotsamStrings.message(for: .capPol001) == advFallbackText)
    }

    // OC: FR-000-05 guard. Int.max count survives %lld without wrapping.
    @Test("Int.max count is printed in full")
    func intMaxCount() {
        let message = FlotsamStrings.message(for: .capLim003, arguments: [.count(Int.max)])
        #expect(message == "A copy of 9223372036854775807 files was trimmed to the first 500.")
    }

    // OC: FR-000-05. Catalogue loading failures return .sysInt001 instead of trapping.
    @Test("empty, malformed and truncated catalogue bytes fail with SYS-INT-001")
    func malformedCatalogue() {
        let inputs: [Data] = [
            Data(),
            Data("not json".utf8),
            Data("{\"strings\":".utf8),
            Data("[]".utf8),
            Data("{}".utf8),
            Data([0xFF, 0xFE, 0x00, 0xD8]),
        ]
        for input in inputs {
            switch FlotsamCatalogue.englishStrings(from: input) {
            case .success(let strings):
                // {} is a valid empty catalogue only if it yields no strings; anything else is a parse of garbage
                #expect(strings.isEmpty)
            case .failure(let error):
                #expect(error.code == .sysInt001)
            }
        }
    }

    // OC: FR-000-05. Missing catalogue file fails with SYS-INT-001.
    @Test("a missing catalogue file fails with SYS-INT-001")
    func missingCatalogueFile() {
        let url = URL(fileURLWithPath: "/nonexistent-8a-dir/Localizable.xcstrings")
        guard case .failure(let error) = FlotsamCatalogue.englishStrings(at: url) else {
            Issue.record("expected failure for missing file")
            return
        }
        #expect(error.code == .sysInt001)
    }
}

// MARK: - Privacy (FR-000-10)

@Suite("8A FRD-000 log privacy")
struct Adversarial000PrivacyTests {
    // OC: FR-000-10. Every non-allowlisted value must stay out of publicText on every path (error, event, trace).
    @Test("ids, bundle ids and unknown pasteboard types never reach publicText")
    func privateValuesStayPrivate() throws {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let bundle = try #require(BundleIdentifier("com.secret.app"))
        let context: [LogKey: LogSafeValue] = [
            .itemId: .id(uuid),
            .bundleId: .bundleId(bundle),
            .uti: .uti(PasteboardTypeID("dyn.ah62d4rv4ge81g6xy")),
            .count: .int(7),
        ]
        let error = FlotsamError(
            .capOs001, "secret developer text",
            context: context,
            underlying: UnderlyingErrorInfo(domain: "SecretDomain", code: 9)
        )
        let sink = AdvSink()
        FlotsamLog.log(error, sink: sink)
        let event = LogEvent.pasteboardProcessed(kind: .text, byteSize: 5, outcome: .stored, policy: nil)
        FlotsamLog.log(event, sink: sink)
        let record = try #require(sink.records.first)
        let pub = record.publicText
        #expect(!pub.contains("11111111"))
        #expect(!pub.contains("com.secret.app"))
        #expect(!pub.contains("dyn."))
        #expect(!pub.contains("secret developer text"))
        #expect(!pub.contains("SecretDomain"))
        #expect(pub.contains("count=7"))
        #expect(record.privateText.contains("11111111-2222-3333-4444-555555555555"))
        #expect(record.privateText.contains("SecretDomain:9"))
        #expect(sink.records.count == 2)
        #expect(sink.records[1].publicText == "pasteboard.processed byteSize=5B kind=text outcome=stored")
    }

    // OC: FR-000-10. A UTI is public only when it is exactly a system-declared identifier, no suffix tricks.
    @Test("UTI allowlist is exact: suffixed, padded or case-changed identifiers are private")
    func utiAllowlistIsExact() {
        let cases: [(String, Bool)] = [
            ("public.utf8-plain-text", true),
            ("public.utf8-plain-text ", false),
            ("public.utf8-plain-text\n/Users/me/secret.txt", false),
            ("Public.utf8-plain-text", false),
            ("public.utf8-plain-text.user-typed-this", false),
            ("", false),
        ]
        for (identifier, expectedPublic) in cases {
            #expect(LogSafeValue.uti(PasteboardTypeID(identifier)).isPublic == expectedPublic, "\(identifier.debugDescription)")
        }
    }

    // OC: FR-000-10. BundleIdentifier shape validation: accepts only reverse-DNS, rejects everything a path, URL or sentence has.
    @Test("bundle identifier validation rejects paths, URLs, sentences, unicode and 256-byte values")
    func bundleIdentifierShape() {
        let accepted = ["com.apple.finder", "a.b", String(repeating: "a", count: 253) + ".b"]
        let rejected = [
            "", "com", "com.", ".com", "com..apple", "com.apple finder", "com.apple\nfinder", "com.apple.fi/nder",
            "https://x.y", "me@x.y", "com.épicé", "com.apple.e\u{0301}", "com.apple.\u{202E}finder", "a/b.c",
            String(repeating: "a", count: 254) + ".b",
        ]
        for value in accepted { #expect(BundleIdentifier(value) != nil, "\(value.debugDescription)") }
        for value in rejected { #expect(BundleIdentifier(value) == nil, "\(value.debugDescription)") }
    }

    // OC: FR-000-10. Dumping the whole record for a hostile error: the only dynamic public tokens are code, severity and allowlisted context.
    @Test("hostile underlying domain and static message stay in privateText")
    func hostileCauseStaysPrivate() {
        let error = FlotsamError(
            .libOs001, "msg with /Users/someone/secret.txt",
            underlying: UnderlyingErrorInfo(domain: "/Users/someone/secret.txt", code: -1)
        )
        let record = FlotsamLog.record(for: error)
        #expect(record.publicText == "LIB-OS-001 error")
        #expect(record.privateText.contains("/Users/someone/secret.txt"))
    }
}

// MARK: - Architecture lint (FR-000-02, FR-000-09)

/// Runs a copy of bin/check-architecture.sh against a throwaway tree holding one fixture file, so the repo is never touched.
enum AdvLintHarness {
    static var repoRoot: URL {
        // .../Packages/FlotsamCore/Tests/FlotsamBaseTests/<this file>
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    /// Exit status of the lint on a tree containing only `source`, written to `relativePath` under Sources/.
    /// `extraFiles` maps a path relative to the tree root (e.g. "project.yml") to its contents; Package.swift may be overridden the same way.
    static func exitStatus(for source: String, at relativePath: String = "FlotsamBase/Fixture.swift",
                           extraFiles: [String: String] = [:]) async throws -> Int32 {
        try await run(source, at: relativePath, extraFiles: extraFiles).status
    }

    /// Whether the lint reports the fatalError/precondition rule on a tree holding only `source` (other rules may fire too).
    static func reportsFatal(_ source: String) async throws -> Bool {
        try await run(source).output.contains("fatalError/precondition without")
    }

    static func run(_ source: String, at relativePath: String = "FlotsamBase/Fixture.swift",
                            extraFiles: [String: String] = [:]) async throws -> ProcessResult {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("flotsam-8a-lint-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let base = root.appendingPathComponent("Packages/FlotsamCore/Sources/FlotsamBase")
        try fm.createDirectory(at: base.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.copyItem(
            at: repoRoot.appendingPathComponent("bin/check-architecture.sh"),
            to: root.appendingPathComponent("bin/check-architecture.sh")
        )
        try Data("{\"strings\":{}}".utf8).write(to: base.appendingPathComponent("Resources/Localizable.xcstrings"))
        let fixture = root.appendingPathComponent("Packages/FlotsamCore/Sources").appendingPathComponent(relativePath)
        try fm.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((source + "\n").utf8).write(to: fixture)
        try Data().write(to: root.appendingPathComponent("Packages/FlotsamCore/Package.swift"))
        for (path, contents) in extraFiles {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((contents + "\n").utf8).write(to: url)
        }

        return try await runProcess("/bin/bash", [root.appendingPathComponent("bin/check-architecture.sh").path])
    }
}

@Suite("8A FRD-000 architecture lint")
struct Adversarial000LintTests {
    // OC: FR-000-02 controls. Without these a lint that always exits 0 would pass the false-negative cases' siblings.
    @Test("controls: real violations fail, clean code passes", arguments: [
        ("let x = try! foo()", Int32(1)),
        ("func f() { print(\"x\") }", Int32(1)),
        ("public func f() throws {}", Int32(1)),
        ("let d: Int? = 1\nlet z = d!", Int32(1)),
        ("let a = 1\nlet b = a != 2\nlet c = !b", Int32(0)),
        ("let s = \"wow!\"\n// x!\nlet t = \"\"\"\nmulti !\n\"\"\"", Int32(0)),
    ])
    func controls(source: String, expected: Int32) async throws {
        #expect(try await AdvLintHarness.exitStatus(for: source) == expected, "\(source.debugDescription)")
    }

    // OC: FR-000-02 / AC-000-01. 8A break, ticket TASK-349. Each shape declares a throwing public API or force-unwrap the lint must catch.
    @Test("false negatives: banned shapes the lint lets through (FR-000-02, TASK-349)", arguments: [
        "public func f(\n    a: Int\n) throws -> Int { a }",
        "public func f(limit: Int = 10) throws -> Int { limit }",
        "public struct S {\n    public var x: Int { get throws { 1 } }\n}",
        "public protocol P {\n    func f() throws\n}",
        "public extension Int {\n    func g() throws {}\n}",
        "public\nfunc f() throws {}",
        "public func f(\n    _ g: () throws -> Void\n) rethrows {}",
        "let d: Int? = 1\nlet s = \"v \\(d!)\"",
        "func f() { Swift.print(\"x\") }",
        "func f() { print (\"x\") }",
        "let ñ: Int? = 1\nlet z = ñ!",
    ])
    func falseNegatives(source: String) async throws {
        #expect(try await AdvLintHarness.exitStatus(for: source) == 1, "\(source.debugDescription)")
    }

    // OC: FR-000-02 / FR-000-09. 8A break, ticket TASK-350. Correct code (banned names only in comments, strings or a block comment) must pass.
    @Test("false positives: correct code the lint rejects (FR-000-02, TASK-350)", arguments: [
        "/// Never call print(x)\nlet a = 1",
        "// avoid try! here\nlet a = 1",
        "let s = \"do not try! this\"",
        "/*\n public func f() throws\n*/\nlet a = 1",
        "/* a /* b */ x! */\nlet a = 1",
        "let s = #\"a \"b!\" c\"#",
    ])
    func falsePositives(source: String) async throws {
        #expect(try await AdvLintHarness.exitStatus(for: source) == 0, "\(source.debugDescription)")
    }
}

// MARK: - TASK-351: every Swift-reading rule goes through the strip pass

/// Where the LOGPRIVACY rule looks (FR-000-10).
private let logFilePath = "FlotsamBase/Logging/FlotsamLog.swift"

/// One banned token wrapped in each comment and string form. Plain-string form escapes quotes so the fixture is valid Swift.
private func hiddenForms(of token: String) -> [String] {
    let escaped = token.replacingOccurrences(of: "\"", with: "\\\"")
    return [
        "// \(token)\nlet ok = 1",
        "/// \(token)\nlet ok = 1",
        "/* \(token) */\nlet ok = 1",
        "/* a /* b */\n\(token)\n*/\nlet ok = 1",
        "let s = \"\(escaped)\"",
        "let s = ##\"\(token) \"# \"##",
        "let s = \"\"\"\n\(token)\n\"\"\"",
        "let s = #\"\"\"\n\(token)\n\"\"\"#",
    ]
}

private let strippedTokens = [
    "fatalError(\"x\")", "e.localizedDescription", "Logger(subsystem: \"a\", category: \"b\")", "Text(\"hello\")",
    "import Sentry", "try! f()", "UserDefaults.standard", "URLSession.shared",
]

@Suite("8A TASK-351 strip pass")
struct Adversarial000Task351Tests {
    // OC: FR-000-02 / TASK-351. Mutation: running the FATAL/LOCDESC/LOGGER/USTRING/NETWORK/USERDEFAULTS/SDKIMPORT rules on the raw line
    // (the pre-d998813 script) turns every row red. Control: the same token as bare code exits 1, so a lint that always exits 0 fails here.
    @Test("a banned token in any comment or string form passes; the same token as code fails",
          arguments: strippedTokens)
    func tokensHiddenInCommentsAndStringsPass(token: String) async throws {
        // given the token bare, when linted, then it fails (control)
        #expect(try await AdvLintHarness.exitStatus(for: token) == 1, "control \(token.debugDescription)")
        // given the token in each comment/string form, when linted, then every one passes
        for source in hiddenForms(of: token) {
            #expect(try await AdvLintHarness.exitStatus(for: source) == 0, "\(source.debugDescription)")
        }
    }

    // OC: FR-000-02 / TASK-351. Mutation: blanking the whole string literal (dropping the interpolation code) turns these green->red.
    @Test("a banned expression inside an interpolation is still code and fails", arguments: [
        "fatalError(\"x\")", "e.localizedDescription", "Logger(subsystem: \"a\", category: \"b\")", "os_log(\"x\")",
        "URLSession.shared", "UserDefaults.standard", "d!", "try! f()",
    ])
    func interpolationCodeIsStillChecked(expression: String) async throws {
        // given the expression inside each interpolation form, when linted, then it fails
        let sources = [
            "let s = \"a \\(\(expression)) b\"",
            "let s = \"\"\"\nline \\(\(expression))\n\"\"\"",
            "let s = #\"a \\#(\(expression)) b\"#",
            "let s = \"a \\(\"b \\(\(expression))\")\"",
            "let s = \"\"\"\n\\(\n\(expression)\n)\n\"\"\"",
        ]
        for source in sources {
            #expect(try await AdvLintHarness.exitStatus(for: source) == 1, "\(source.debugDescription)")
        }
        // given a raw string where \( is plain text, when linted, then it passes (negative)
        #expect(try await AdvLintHarness.exitStatus(for: "let s = #\"\\(\(expression))\"#") == 0)
    }

    // OC: FR-000-02 / TASK-351. Mutation: a strip pass that mis-tracks a delimiter (an unclosed comment or string state leaking
    // past its closer) hides the fatalError on each row; a lint that does not strip at all fails the first row of the next test.
    @Test("real code after a comment or string closer on the same or a later line fails", arguments: [
        "/* c */ fatalError(\"x\")",
        "/* a /* b */ still comment */ fatalError(\"x\")",
        "let s = \"x\"; fatalError(\"x\")",
        "let s = \"//\"; fatalError(\"x\")",
        "let s = \"/*\"\nfatalError(\"x\")",
        "// it's \"\nfatalError(\"x\")",
        "// /*\nfatalError(\"x\")",
        "/* \" */ fatalError(\"x\")",
        "/* // */ fatalError(\"x\")",
        "/* \"\"\" */ fatalError(\"x\")",
        "let s = \"a\\\\\"; fatalError(\"x\")",
        "let s = \"\"\"\nabc\n\"\"\"; fatalError(\"x\")",
        "let s = \"a \\(f(\")\")) b\"; fatalError(\"x\")",
        "public func f(\n    a: String = \"(\",\n    b: Int\n) throws {}",
    ])
    func codeAfterCloserIsStillChecked(source: String) async throws {
        // given code after a closer, when linted, then it fails
        #expect(try await AdvLintHarness.exitStatus(for: source) == 1, "\(source.debugDescription)")
    }

    @Test("text that only looks like code inside comments and strings passes", arguments: [
        "/* a /* b */ fatalError(\"x\") */\nlet a = 1",
        "let s = \"a\\\" fatalError(\\\"x\\\") b\"",
        "let s = \"\"\"\nsay \"try! x\" and \"\"fatalError(\"x\")\"\"\n\"\"\"",
        "let s = \"\"\"\nabc \\\nfatalError(\"x\")\n\"\"\"",
        "// import Sentry\n/* import GRDB */\nimport Foundation",
    ])
    func lookalikesPass(source: String) async throws {
        // given code-looking text in comments/strings, when linted, then it passes
        #expect(try await AdvLintHarness.exitStatus(for: source) == 0, "\(source.debugDescription)")
    }

    // OC: FR-000-04 / 8A ruling "fatal-ok on the same line". Mutation: reading the annotation from the raw line (not the comment text)
    // lets a `fatal-ok:` string literal waive the rule, turning the string rows red.
    @Test("fatal-ok waives only from a comment on the same line", arguments: [
        ("func f() { fatalError(\"x\") } // fatal-ok: invariant", Int32(0)),
        ("precondition(x) // fatal-ok: y", Int32(0)),
        ("func f() { fatalError(\"fatal-ok: reason\") }", Int32(1)),
        ("let s = \"fatal-ok:\"; fatalError(\"x\")", Int32(1)),
        ("func f() { fatalError(#\"fatal-ok: r\"#) }", Int32(1)),
        ("let s = \"\"\"\nfatal-ok: why\n\"\"\"\nfatalError(\"x\")", Int32(1)),
        ("// fatal-ok: x\nfatalError(\"x\")", Int32(1)),
        ("fatalError(\"x\")", Int32(1)),
    ])
    func fatalOkOnlyFromSameLineComment(source: String, expected: Int32) async throws {
        // given a fatalError with or without an annotation, when linted, then only a same-line comment annotation passes
        #expect(try await AdvLintHarness.exitStatus(for: source) == expected, "\(source.debugDescription)")
    }

    // OC: FR-000-10 / TASK-351. Mutation: reading `privacy:` from the raw line lets a string or comment mention waive an unqualified interpolation.
    @Test("log privacy: only a real qualifier in code waives it", arguments: [
        ("func f(v: Int, logger: Logger) {\n  logger.info(\"a \\(v)\")\n}", Int32(1)),
        ("func f(v: Int, logger: Logger) {\n  logger.info(\"a \\(v, privacy: .public)\")\n}", Int32(0)),
        ("func f(v: Int, logger: Logger) {\n  logger.info(\n    \"a \\(v)\"\n  )\n}", Int32(1)),
        ("func f(v: Int, logger: Logger) {\n  logger.info(\"privacy: \\(v)\")\n}", Int32(1)),
        ("func f(v: Int, logger: Logger) {\n  logger.info(\"a \\(v)\") // privacy: .public\n}", Int32(1)),
        ("func f(v: Int, logger: Logger) {\n  logger.info(\n    // privacy: .public\n    \"a \\(v)\"\n  )\n}", Int32(1)),
        ("func f(v: Int, logger: Logger) {\n  logger.info(\"\"\"\n  x \\(v)\n  \"\"\")\n}", Int32(1)),
        ("func f(v: Int, logger: Logger) {\n  logger.info(\"a\") // \\(v)\n}", Int32(0)),
        ("func f(v: Int, logger: Logger) {\n  logger.info(#\"a \\(v)\"#)\n}", Int32(0)),
    ])
    func logPrivacyReadsCodeOnly(source: String, expected: Int32) async throws {
        // given a Logger call in FlotsamLog.swift, when linted, then only an unqualified interpolation in code fails
        #expect(try await AdvLintHarness.exitStatus(for: source, at: logFilePath) == expected, "\(source.debugDescription)")
    }
}

// MARK: - TASK-351 breaks found by blind verification (fixed in TASK-353...359)

/// One test per ticket. Each pins a shape the lint once let through (or wrongly rejected); the controls prove the lint still
/// fails real violations, so a lint that always exits 0 (or 1) cannot pass.
@Suite("8A TASK-351 lint breaks, fixed")
struct Adversarial000Task351BreakTests {
    /// Asserts every control exits 1 and every shape exits `expected`.
    private func pin(_ shapes: [String], controls: [String], expected: Int32, at path: String = "FlotsamBase/Fixture.swift",
                     ticket: String) async throws {
        for control in controls {
            #expect(try await AdvLintHarness.exitStatus(for: control, at: path) == 1, "control \(control.debugDescription)")
        }
        for shape in shapes {
            #expect(try await AdvLintHarness.exitStatus(for: shape, at: path) == expected, "\(ticket): \(shape.debugDescription)")
        }
    }

    // OC: FR-000-02. TASK-353 (regression from the strip pass). Mutation that turns it red: lex `/.../` regex literals in san_line.
    @Test("TASK-353: a regex literal containing a quote hides the rest of the line")
    func regexLiteralQuote() async throws {
        // given a regex literal with a quote followed by fatalError, when linted, then it fails
        try await pin(["let r = /\"/; fatalError(\"x\")"], controls: ["let r = 1; fatalError(\"x\")"], expected: 1, ticket: "TASK-353")
    }

    // OC: FR-000-04 / FR-000-09. TASK-354. Mutation: allow `[ \t]*` and a newline between the name and `(` in FATAL/LOGGER.
    @Test("TASK-354: a space or newline before the paren slips past FATAL and LOGGER")
    func spacedCallShapes() async throws {
        try await pin([
            "fatalError (\"x\")", "precondition (false)", "let l = Logger (subsystem: \"a\", category: \"b\")", "os_log (\"x\")",
            "log.debug (\"x\")", "fatalError\n(\"x\")", "let l = Logger\n(subsystem: \"a\", category: \"b\")", "os_log\n(\"x\")",
            "log.debug\n(\"x\")", "`fatalError`(\"x\")",
        ], controls: [
            "fatalError(\"x\")", "precondition(false)", "let l = Logger(subsystem: \"a\", category: \"b\")", "os_log(\"x\")", "log.debug(\"x\")",
        ], expected: 1, ticket: "TASK-354")
    }

    // OC: FR-000-15 / ADR-0001. TASK-355. Mutation: match imports on the stripped line with optional attributes/access modifiers.
    @Test("TASK-355: attributed, access-level, indented and same-line imports bypass SDK and graph rules")
    func importShapes() async throws {
        try await pin([
            "@preconcurrency import Sentry", "public import Sentry", "internal import Sentry", "@_exported import Sentry",
            "import Foundation; import Sentry", "import\nSentry",
            "@preconcurrency import FlotsamStorage", "public import FlotsamStorage", "@_exported import FlotsamStorage",
            "#if canImport(FlotsamStorage)\n    import FlotsamStorage\n#endif", "import Foundation; import FlotsamStorage",
        ], controls: ["import Sentry", "import FlotsamStorage", "@testable import Sentry"], expected: 1, ticket: "TASK-355")
    }

    // OC: FR-000-10. TASK-356. Mutation: count interpolations against qualifiers per line instead of testing for any `privacy:`.
    @Test("TASK-356: one privacy: qualifier excuses every interpolation on the line")
    func logPrivacyPerInterpolation() async throws {
        try await pin(
            ["func f(v: Int, logger: Logger) {\n  logger.info(\"a \\(v, privacy: .public) b \\(v)\")\n}"],
            controls: ["func f(v: Int, logger: Logger) {\n  logger.info(\"a \\(v)\")\n}"],
            expected: 1, at: logFilePath, ticket: "TASK-356")
    }

    // OC: FR-000-10. TASK-357. Mutation: reset `inlog` when a one-line call's parens balance.
    @Test("TASK-357: an interpolation after a one-line logger call is reported as a log message")
    func logPrivacyLatch() async throws {
        try await pin(
            ["func f(v: Int, logger: Logger) {\n  logger.info(\"a\")\n  let s = \"b \\(v)\"\n}"],
            controls: ["func f(v: Int, logger: Logger) {\n  logger.info(\"a\")\n  logger.info(\"b \\(v)\")\n}"],
            expected: 0, at: logFilePath, ticket: "TASK-357")
    }

    // OC: FR-000-04 / ADR-0009. TASK-358. Mutation: add a left identifier boundary to FATAL, USERDEFAULTS and os_log/.debug.
    @Test("TASK-358: identifiers that merely contain a banned name fail the lint")
    func identifierBoundaries() async throws {
        try await pin([
            "func myfatalError(_ s: String) {}", "notprecondition(1)", "let x = MyUserDefaultsLike()",
        ], controls: ["fatalError(\"x\")", "precondition(false)", "let d = UserDefaults.standard"], expected: 0, ticket: "TASK-358")
    }

    // OC: FR-000-05. TASK-359. Mutation: let USTRING tolerate whitespace/newline before the opening quote and cover verbatim/LocalizedStringKey.
    @Test("TASK-359: user-visible literals split over lines or spaced slip past USTRING")
    func userStringShapes() async throws {
        try await pin([
            "let v = Text(\n\"hello\")", "Button(\n    \"Save\"\n) {}", "x.title =\n    \"hello\"", "v.help(\n\"hi\")",
            "let v = Text (\"hello\")", "let v = Text(verbatim: \"hello\")", "let v = Text(LocalizedStringKey(\"hello\"))",
        ], controls: ["let v = Text(\"hello\")", "v.help(\"hi\")", "x.title = \"hello\""], expected: 1, ticket: "TASK-359")
    }
}


// MARK: - Kill-check pins and known issues found verifying TASK-353...359 (Worf, 2026-11-17)

/// Each passing test below was added because a mutant of the lint (named on the test) survived the seven TASK-353...359 tests.
/// The known-issue tests pin defects that are still present; each goes red the moment its defect is fixed, which is the cue to
/// remove the `withKnownIssue` wrapper.
@Suite("8A TASK-353..359 kill-check pins")
struct Adversarial000KillCheckPins {
    private func status(_ source: String, at path: String = "FlotsamBase/Fixture.swift", extra: [String: String] = [:]) async throws -> Int32 {
        try await AdvLintHarness.exitStatus(for: source, at: path, extraFiles: extra)
    }

    // OC: FR-000-02. TASK-353. Mutant that turns it red: stop lexing `#/ ... /#` raw regex literals in san_line.
    @Test("TASK-353: a raw #/ /# regex literal containing a quote does not hide the rest of the line")
    func rawRegexLiteralQuote() async throws {
        // given a raw regex literal holding a quote, when it is followed by fatalError, then the lint fails; the same literal alone passes
        #expect(try await status("let r = #/\"/#; fatalError(\"x\")") == 1)
        #expect(try await status("let r = #/\"/#; let s = 1") == 0)
    }

    // OC: FR-000-04. TASK-354. Mutant: drop preconditionFailure from the FATAL alternation (precondition( does not match preconditionFailure().
    @Test("TASK-354: preconditionFailure, spaced or split over a line, fails FATAL; a longer identifier and a waiver pass")
    func preconditionFailureShapes() async throws {
        // given preconditionFailure calls, when linted, then they fail; given an identifier that merely starts with it, or a waiver, then pass
        for shape in ["preconditionFailure(\"x\")", "preconditionFailure (\"x\")", "preconditionFailure\n(\"x\")"] {
            #expect(try await status(shape) == 1, "\(shape.debugDescription)")
        }
        #expect(try await status("let preconditionFailureCount = 1") == 0)
        #expect(try await status("preconditionFailure(\"x\") // fatal-ok: unreachable by construction") == 0)
    }

    // OC: FR-000-15 / ADR-0001. TASK-355. Mutant: stop skipping the import kind keyword (import struct Foo.Bar), so the module reads as `struct`.
    @Test("TASK-355: import with a kind keyword still names its module")
    func importKindKeyword() async throws {
        // given kind-keyword imports of a banned SDK and of a module the target may not import, when linted, then they fail; Foundation passes
        for shape in ["import func Sentry.capture", "import struct Sentry.Scope", "import struct FlotsamStorage.Thing", "import class FlotsamStorage.X"] {
            #expect(try await status(shape) == 1, "\(shape.debugDescription)")
        }
        #expect(try await status("import struct Foundation.Date") == 0)
    }

    // OC: FR-000-15. TASK-355. Mutant: MANIFEST rule reads the raw line instead of the strip-pass text, so comments in manifests fail.
    @Test("TASK-355: an SDK name in a manifest fails; the same name in a comment passes")
    func manifestSdkNames() async throws {
        // given project.yml declaring Sentry, when linted, then it fails; given Sentry only in # comments (own line or trailing), then it passes
        let declared = "packages:\n  Sentry:\n    url: https://example.test/x"
        #expect(try await status("let ok = 1", extra: ["project.yml": declared]) == 1)
        #expect(try await status("let ok = 1", extra: ["project.yml": "# we never ship Sentry\nname: Flotsam"]) == 0)
        #expect(try await status("let ok = 1", extra: ["project.yml": "name: Flotsam # not Sentry"]) == 0)
        // given Package.swift with a Sentry comment, then it passes; given a Sentry string (the url) in a non-comment, then it fails
        let pkgComment = "// import Sentry is banned\nlet package = 1"
        #expect(try await status("let ok = 1", extra: ["Packages/FlotsamCore/Package.swift": pkgComment]) == 0)
        let pkgUrl = "let deps = [\"https://github.com/getsentry/sentry-cocoa\"]"
        #expect(try await status("let ok = 1", extra: ["Packages/FlotsamCore/Package.swift": pkgUrl]) == 1)
    }

    // OC: FR-000-09 / ADR-0009. TASK-358. Mutant: drop the left identifier boundary from the LOGGER os_log and Logger patterns.
    @Test("TASK-358: identifiers ending in Logger or os_log do not fail LOGGER; the real calls do")
    func loggerLeftBoundary() async throws {
        // given my_os_log( and MyLogger(, when linted, then they pass; given os_log( and Logger(, then they fail
        #expect(try await status("my_os_log(\"x\")") == 0)
        #expect(try await status("let l = MyLogger(subsystem: \"a\")") == 0)
        #expect(try await status("os_log(\"x\")") == 1)
        #expect(try await status("let l = Logger(subsystem: \"a\", category: \"b\")") == 1)
    }

    // OC: FR-000-05. TASK-359. Mutants: drop the whitespace allowance before `(` on .help, and the newline allowance after `withTitle:`.
    @Test("TASK-359: .help spaced before the paren and withTitle: split over a line fail USTRING; a non-literal passes")
    func userStringHelpAndWithTitle() async throws {
        // given a literal passed through those two shapes, when linted, then it fails; given a similarly named method or a variable, then it passes
        #expect(try await status("v.help (\"hi\")") == 1)
        #expect(try await status("a.addButton(withTitle:\n\"Quit\")") == 1)
        #expect(try await status("a.addButton(withTitle: \"Quit\")") == 1)
        #expect(try await status("v.helper (\"hi\")") == 0)
        #expect(try await status("a.addButton(withTitle: key)") == 0)
    }

    // MARK: TASK-365 / TASK-366 (fixed in 2ed68a4 / e7a0510), pins added verifying them

    // OC: FR-000-02. TASK-365. A line that STARTS with `/` (a division continued from the line above) must not open a regex literal
    // that closes at the next `/` on that line and hides a banned call between the two slashes.
    @Test("TASK-365: a continued-division line starting with / does not hide a banned call before the second slash")
    func divisionAtLineStartHidesViolation() async throws {
        // given fatalError between two slashes on a line that starts with `/`, when linted, then it fails
        let hidden = try await status("let r = total\n    /n + g(fatalError(\"x\"))/2")
        #expect(hidden == 1)
        // control: the same body without the slashes fails, so the shape above is the only thing hiding it
        #expect(try await status("let r = total\n    + g(fatalError(\"x\"))") == 1)
    }

    // OC: FR-000-10. TASK-366. LOGCALL covers every os Logger level, a receiver named log, and a newline before `(`.
    @Test("TASK-366: LOGPRIVACY sees .trace/.warning/.critical, a receiver named log, and a newline before the paren")
    func logPrivacyCallShapeGaps() async throws {
        let shapes = [
            "func f(v: Int, logger: Logger) {\n  logger.warning(\"a \\(v)\")\n}",
            "func f(v: Int, logger: Logger) {\n  logger.trace(\"a \\(v)\")\n}",
            "func f(v: Int, logger: Logger) {\n  logger.critical(\"a \\(v)\")\n}",
            "func f(v: Int, log: Logger) {\n  log.info(\"a \\(v)\")\n}",
            "func f(v: Int, logger: Logger) {\n  logger.info\n  (\"a \\(v)\")\n}",
        ]
        // control: the recognised shape fails
        #expect(try await status("func f(v: Int, logger: Logger) {\n  logger.info(\"a \\(v)\")\n}", at: logFilePath) == 1)
        for shape in shapes {
            // given an unqualified interpolation in FlotsamLog.swift, when linted, then it fails
            let code = try await status(shape, at: logFilePath)
            #expect(code == 1, "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-09. TASK-366. A backticked method name does not slip past the `.debug(` pattern in LOGGER.
    @Test("TASK-366: log.`debug`(...) outside FlotsamLog.swift fails LOGGER")
    func backtickedDebugMiss() async throws {
        let backticked = try await status("log.`debug`(\"x\")")
        #expect(backticked == 1)
        #expect(try await status("log.debug(\"x\")") == 1)
    }

    // MARK: mutation pins for the TASK-365 / TASK-366 fixes (Worf, 2026-11-17)

    private func logStatus(_ body: String) async throws -> Int32 {
        try await status("func f(v: Int, logger: Logger) {\n  \(body)\n}", at: logFilePath)
    }

    // OC: FR-000-02. TASK-365. Mutants: prevcode reset on a comment/blank line (`prevcode = o` unconditionally); prevcode not reset at a
    // file boundary; the first code line of a file judged division; prevcode kept with trailing whitespace.
    @Test("TASK-365: the previous CODE line decides a line-start /, across comments, blanks, files and trailing spaces")
    func lineStartSlashUsesPreviousCodeLine() async throws {
        let body = "    /n + g(fatalError(\"x\"))/2"
        // given a division continued across a comment line, a blank line or a block comment, when linted, then fatalError is still seen
        for between in ["// c", "", "/* c */", "/// doc"] {
            #expect(try await status("let r = total\n\(between)\n\(body)") == 1, "between \(between.debugDescription)")
        }
        // given a division after a string, a closing paren/brace/bracket, a multi-line string and a regex, then fatalError is still seen
        for prev in ["let s = \"a/\"", "let r = (a + b)", "let r = { 1 }", "let r = a[0]", "let s = \"\"\"\n  abc\n  \"\"\"", "let r = /a/"] {
            #expect(try await status("\(prev)\n\(body)") == 1, "after \(prev.debugDescription)")
        }
        // given a regex after `=` with trailing whitespace, a comment, a blank line, or inside an array, then it is a regex and passes unless a banned token is outside it
        #expect(try await status("let r = \t\n    /\"/; fatalError(\"x\")") == 1)
        #expect(try await status("let r = \n    /\"/; fatalError(\"x\")") == 1)
        #expect(try await status("let r = // c\n    /fatalError(x)/") == 0)
        #expect(try await status("let r =\n\n    /fatalError(x)/") == 0)
        #expect(try await status("let rs = [\n    /fatalError(x)/,\n    /print(y)/\n]") == 0)
        // given a regex that opens a file (after only comments), then it is a regex; the same shape in the second file starts fresh
        #expect(try await status("/\"/; fatalError(\"x\")") == 1)
        #expect(try await status("// header\n\n/\"/; fatalError(\"x\")") == 1)
        let second = ["Packages/FlotsamCore/Sources/FlotsamBase/B.swift": "/\"/; fatalError(\"x\")"]
        #expect(try await status("let a = total", at: "FlotsamBase/A.swift", extra: second) == 1)
        // given the keyword `return` before a line-start regex, then it is a regex
        #expect(try await status("func f() { return\n    /\"/; fatalError(\"x\") }") == 1)
    }

    // OC: FR-000-10. TASK-366. Mutants: drop any one of log/info/notice/error/fault/debug from LOGCALL.
    @Test("TASK-366: every os Logger level fails LOGPRIVACY on an unqualified interpolation")
    func everyLoggerLevel() async throws {
        // given each level, when linted in FlotsamLog.swift, then it fails; the qualified form passes
        for level in ["log", "info", "notice", "error", "fault", "debug", "trace", "warning", "critical"] {
            #expect(try await logStatus("logger.\(level)(\"a \\(v)\")") == 1, "\(level)")
            #expect(try await logStatus("logger.\(level)(\"a \\(v, privacy: .public)\")") == 0, "\(level) qualified")
        }
    }

    // OC: FR-000-10. TASK-366. Mutants: `_?` dropped; left identifier boundary dropped; Logger(...) alternative dropped; optional backticks dropped.
    @Test("TASK-366: receiver shapes (_log, self.log, Logger(...), backticked level) fail; catalog.info, blog.info do not")
    func receiverShapes() async throws {
        let call = "(\"a \\(v)\")"
        // given each recognised receiver, when linted in FlotsamLog.swift, then it fails
        for shape in ["_log.info", "self.log.info", "Logger(subsystem: \"a\", category: \"b\").info", "logger.`info`", "log.`warning`"] {
            #expect(try await status("func f(v: Int) {\n  \(shape)\(call)\n}", at: logFilePath) == 1, "\(shape)")
        }
        // given a receiver that merely ends in log, when linted, then it is not a log call and passes
        for shape in ["catalog.info", "blog.info", "x$log.info"] {
            #expect(try await status("func f(v: Int) {\n  \(shape)\(call)\n}", at: logFilePath) == 0, "\(shape)")
        }
    }

    // OC: FR-000-10. TASK-366. Mutants: pend cleared by a blank/comment line; `(` consumed twice (i = q); a non-call reference opens a call.
    @Test("TASK-366: the paren may follow after blank/comment lines or a space; a reference that is not a call opens nothing")
    func parenPlacement() async throws {
        // given the paren after a blank line, a comment line, trailing whitespace or a space, when linted, then the interpolation is checked
        #expect(try await logStatus("logger.info\n\n  (\"a \\(v)\")") == 1)
        #expect(try await logStatus("logger.info\n  // c\n  (\"a \\(v)\")") == 1)
        #expect(try await logStatus("logger.info  \n  (\"a \\(v)\")") == 1)
        #expect(try await logStatus("logger.info (\"a \\(v)\")") == 1)
        #expect(try await logStatus("logger.info\n  (\"a \\(v, privacy: .public)\")") == 0)
        // given a call that closes, on the same line, a space before the paren, or the next line, then a later plain string is not a log message
        #expect(try await logStatus("logger.info\n  (\"a\")\n  let s = \"b \\(v)\"") == 0)
        #expect(try await logStatus("logger.info (\"a\")\n  let s = \"b \\(v)\"") == 0)
        #expect(try await logStatus("logger.info\n  (\"a \\(v, privacy: .public)\")\n  let s = \"b \\(v)\"") == 0)
        // given a reference to a log method that is never called, then a later plain string is not a log message
        #expect(try await logStatus("let h = logger.info\n  let s = \"b \\(v)\"") == 0)
        #expect(try await logStatus("let h = logger.info\n  = 1\n  let s = \"b \\(v)\"") == 0)
        #expect(try await logStatus("let h = logger.info; let s = \"b \\(v)\"") == 0)
        #expect(try await logStatus("use(logger.info, logger.error)\n  let s = \"b \\(v)\"") == 0)
    }

    // OC: FR-000-09. TASK-366. Mutants: drop the leading or the trailing optional backtick, or the newline allowance, in the LOGGER `.debug(` pattern.
    @Test("TASK-366: .debug in every backtick and newline shape fails LOGGER; a longer name passes")
    func debugShapes() async throws {
        for shape in ["log.`debug`(\"x\")", "log.`debug(\"x\")", "log.debug`(\"x\")", "log.`debug`\n(\"x\")", "log.debug (\"x\")"] {
            #expect(try await status(shape) == 1, "\(shape.debugDescription)")
        }
        #expect(try await status("log.debugger(\"x\")") == 0)
    }

    // MARK: TASK-367 / TASK-368 (fixed; the withKnownIssue wrappers are removed)

    // OC: FR-000-02. TASK-368. Was a defect: a line-start regex after a line ending in `}`, `)`, a string, a regex or a `#if` line is read as
    // division (judged by the previous code line), so its text is linted as code. New since 2ed68a4; RegexBuilder is the real shape.
    @Test("KNOWN TASK-368: a statement-position regex literal after a code line is linted as code")
    func statementPositionRegexAfterCodeLine() async throws {
        let shapes = [
            "let r = Regex {\n    /a/\n    /x!/\n}",
            "let r = Regex {\n    Capture(.digit)\n    /print(x)/\n}",
            "let r = Regex {\n    Capture { /\\d+/ }\n    /fatalError(x)/\n}",
            "#if DEBUG\n/fatalError(x)/\n#endif",
        ]
        // control: the same regex after `let r =` is a regex and passes
        #expect(try await status("let r =\n    /fatalError(x)/") == 0)
        for shape in shapes {
            // given a regex literal on its own line after a code line, when linted, then it passes
            #expect(try await status(shape) == 0, "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-02. TASK-368. Was a defect: a previous line ending in `?` makes the next line-start / a regex, hiding a banned call (pre-existing).
    @Test("KNOWN TASK-368: a division continued after a line ending in ? hides a banned call")
    func divisionAfterQuestionMark() async throws {
        // control: the same continuation after a plain identifier fails
        #expect(try await status("let r = total\n    /n + g(fatalError(\"x\"))/2") == 1)
        // given optional-chaining then a continued division, when linted, then it fails
        #expect(try await status("let r = total?\n    /n + g(fatalError(\"x\"))/2") == 1)
    }

    // OC: FR-000-05 / FR-000-04. TASK-367. Was a defect: USTRING view names have no left identifier boundary, and NETWORK is a bare substring match,
    // so a type that merely contains Text/Button/URLSession fails the lint. False positives only; no violation can pass because of it.
    @Test("KNOWN: identifiers that contain a view or network name fail the lint")
    func missingLeftBoundaryFalsePositives() async throws {
        let shapes = ["let v = MyText(\"hello\")", "let v = AppButton(\"Save\")", "let myURLSessionHelper = 1"]
        // control: the real shapes fail
        #expect(try await status("let v = Text(\"hello\")") == 1)
        #expect(try await status("let s = URLSession.shared") == 1)
        for shape in shapes {
            // given an identifier that only contains the banned name, when linted, then it passes
            #expect(try await status(shape) == 0, "\(shape.debugDescription)")
        }
    }
}

// MARK: - TASK-367 / TASK-368 blind verification (Worf, 2026-11-18)

/// Pins the lint behaviour TASK-367 (left identifier boundaries) and TASK-368 (statement-position regex vs continued division)
/// must keep, and the shapes the same change newly lets through. Every expected value is a literal exit status.
@Suite("8A TASK-367/368 lint boundaries and regex judgment")
struct Adversarial000Task367368Verification {
    private func status(_ source: String) async throws -> Int32 {
        try await AdvLintHarness.exitStatus(for: source)
    }

    // OC: FR-000-02. TASK-367. Mutant that turns it red: drop the left boundary from the LOCDESC rule (`t ~ /localizedDescription/`).
    @Test("TASK-367: an identifier that merely ends in localizedDescription passes; a real access fails")
    func localizedDescriptionLeftBoundary() async throws {
        // given identifiers whose tail is localizedDescription, when linted, then they pass
        for shape in ["let s = mylocalizedDescription", "let s = _localizedDescription", "let s = x1localizedDescription"] {
            #expect(try await status(shape) == 0, "\(shape.debugDescription)")
        }
        // given a bare or member access, when linted, then it fails
        for shape in ["let s = localizedDescription", "let s = e.localizedDescription", "let s = e\n    .localizedDescription", "let s = x?.localizedDescription"] {
            #expect(try await status(shape) == 1, "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-05. TASK-367. Mutant: LocalizedStringKey rule back to lb=0.
    @Test("TASK-367: MyLocalizedStringKey(\"x\") passes; LocalizedStringKey(\"x\") fails, qualified or not")
    func localizedStringKeyLeftBoundary() async throws {
        // given a custom type that contains the name, when linted, then it passes
        #expect(try await status("let v = MyLocalizedStringKey(\"x\")") == 0)
        // given the real type, bare or module-qualified, when linted, then it fails
        #expect(try await status("let v = LocalizedStringKey(\"x\")") == 1)
        #expect(try await status("let v = SwiftUI.LocalizedStringKey(\"x\")") == 1)
    }

    // OC: FR-000-04. TASK-367. Mutant: NETWORK rule back to a substring match (no left boundary).
    @Test("TASK-367: identifiers that merely end in a network name pass")
    func networkNamesLeftBoundary() async throws {
        // given identifiers whose tail is a network name, when linted, then they pass
        for shape in ["let s = MyURLSession.shared", "let s = _URLSession.shared", "let s = x1NWConnection(a)", "let w = MyWKWebView()", "let m = $NWPathMonitor"] {
            #expect(try await status(shape) == 0, "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-04. TASK-367. Mutant: a boundary that needs whitespace on the left (`[ \t]`) or a right boundary on the name.
    @Test("TASK-367: network names keep failing after any non-identifier character and with any suffix")
    func networkNamesStillFail() async throws {
        for shape in [
            "let s = Foundation.URLSession.shared", "let s = [URLSession.shared]", "let s = 1+URLSession.shared",
            "let s = \"\\(URLSession.shared)\"", "let c = URLSessionConfiguration.default",
            "let c = NWConnection(host: h, port: p, using: .tcp)", "let w = WKWebView()", "let m = NWPathMonitor()",
        ] {
            #expect(try await status(shape) == 1, "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-02. TASK-368. Mutants: drop `)`, `]`, a digit, `_`, `$` or an uppercase letter from the operand class that precedes a postfix `?`.
    @Test("TASK-368: every operand shape before a postfix ? makes the next line-start / a division")
    func optionalChainingOperandShapes() async throws {
        let banned = "n + g(fatalError(\"x\"))/2"
        // given an operand ending in an identifier, `)`, `]`, digit, `_`, `$0` or capital, then `?`, then a continued division, when linted, then it fails
        for operand in ["total?", "f()?", "a[0]?", "x1?", "x_?", "_x?", "a$?", "$0?", "X?", "a?.b?"] {
            #expect(try await status("let r = \(operand)\n    /\(banned)") == 1, "line-start after \(operand)")
        }
        // given the same inline, when linted, then it fails
        for operand in ["total?", "f()?", "a[0]?", "(a)?"] {
            #expect(try await status("let r = \(operand)/\(banned)") == 1, "inline after \(operand)")
        }
    }

    // OC: FR-000-02. TASK-368. Mutant: polarity of the postfix-? test flipped, or every ? treated as an operand end.
    @Test("TASK-368: a ternary or ?? operator still makes the following / a regex literal")
    func ternaryQuestionMarkStartsRegex() async throws {
        // given a regex literal after a ternary ?, a ?? or either at a line end, when linted, then the banned-looking text inside it passes
        for shape in [
            "let r = c ? /fatalError(x)/ : /y/", "let r = c ?\n    /fatalError(x)/ : /y/",
            "let r = a ?? /fatalError(x)/", "let r = a ??\n    /fatalError(x)/",
        ] {
            #expect(try await status(shape) == 0, "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-02. TASK-368. Mutants: the comment alternatives dropped from the tail test; the tail not trimmed.
    @Test("TASK-368: a statement-position regex may be followed by a comment; followed by code it is not hidden")
    func statementRegexTail() async throws {
        let open = "let r = Regex {\n    Capture(.digit)\n"
        // given a regex line ending in a line comment or a block comment, when linted, then it passes
        #expect(try await status(open + "    /fatalError(x)/ // why\n}") == 0)
        #expect(try await status(open + "    /fatalError(x)/ /* why */\n}") == 0)
        #expect(try await status(open + "    /fatalError(x)/\n}") == 0)
        // given real code after the regex on the same line, when linted, then the code is still seen
        #expect(try await status(open + "    /a/; fatalError(\"x\")\n}") == 1)
        #expect(try await status(open + "    /a/\n}\nfatalError(\"x\")") == 1)
    }

    // OC: FR-000-05. TASK-367. Mutant: any of these names dropped from the USTRING view-name list. SwiftUI views whose names end in a
    // listed name (DatePicker, NavigationLink, ...) take a LocalizedStringKey title, so a literal title is a FR-000-05 violation.
    @Test("TASK-367: SwiftUI views whose names end in a listed view name are still flagged")
    func suffixedSwiftUIViewsStillFlagged() async throws {
        for shape in [
            "let v = Picker(\"When\", selection: $d) {}", "let v = Link(\"Go\", destination: u)",
            "let v = DatePicker(\"When\", selection: $d)", "let v = ColorPicker(\"Tint\", selection: $c)",
            "let v = NavigationLink(\"Go\") { X() }", "let v = ShareLink(\"Share\", item: u)",
            "let v = CommandMenu(\"Tools\") {}", "let v = PhotosPicker(\"Pick\", selection: $s)",
            "let v = MultiDatePicker(\"When\", selection: $s)", "let v = TextFieldLink(\"Go\") { }",
            "let v = Tab(\"Home\", systemImage: \"house\") { }", "let v = TabSection(\"More\") { }",
            "let v = LabeledContent(\"Name\") { }", "let v = ControlGroup(\"Edit\") { }",
            "let v = ProgressView(\"Loading\")", "let v = ContentUnavailableView(\"None\", systemImage: \"x\")",
            "let v = Window(\"Main\", id: \"m\") { }", "let v = WindowGroup(\"Main\") { }",
            "let v = Toggle(\"On\", isOn: $b)", "let v = Stepper(\"N\", value: $n)", "let v = Label(\"T\", systemImage: \"x\")",
            "let v = Section(\"S\") { }", "let v = Menu(\"M\") { }", "let v = TextField(\"T\", text: $t)",
            "let v = SecureField(\"T\", text: $t)", "let v = GroupBox(\"G\") { }", "let v = DisclosureGroup(\"D\") { }",
        ] {
            // given a SwiftUI view with a literal title, when linted, then it fails
            #expect(try await status(shape) == 1, "\(shape.debugDescription)")
        }
        // given a custom type that merely ends in a view name, when linted, then it passes
        for shape in ["let v = MyPicker(\"x\")", "let v = FooTab(\"x\")", "let v = TabView(\"x\")"] {
            #expect(try await status(shape) == 0, "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-02. TASK-368. Mutant: the keyword test skipped when the text ends in a postfix-looking ? or !.
    @Test("TASK-368: a regex literal after try?, try!, as? or as! is a regex, not a division")
    func regexAfterTryQuestionMark() async throws {
        // control: the same shape after plain `try` is a regex and the call after it is still seen
        #expect(try await status("let r = try /\"/; fatalError(\"x\")") == 1)
        for kw in ["try?", "try!", "x as?", "x as!"] {
            // given a regex with a quote after the keyword, then a real fatalError on the line, when linted, then the call is reported
            #expect(try await AdvLintHarness.reportsFatal("let r = \(kw) /\"/; fatalError(\"x\")"), "quote after \(kw)")
            // given a regex holding banned-looking text, when linted, then the text is not linted as code
            #expect(try await !AdvLintHarness.reportsFatal("let r = \(kw) /fatalError(x)/"), "regex text after \(kw)")
        }
        // given try? with nothing else banned, when linted, then the whole file passes
        #expect(try await status("let r = try? /fatalError(x)/") == 0)
    }

    // OC: FR-000-02. TASK-515. Mutant: `!` left in the expression-start character list (a postfix ! no longer ends an operand).
    @Test("TASK-515: a postfix ! ends an operand, so the / after it is a division; a prefix ! and try! start an expression")
    func postfixForceUnwrapEndsOperand() async throws {
        // given an operand, a postfix !, then a division whose second operand holds a real fatalError, when linted, then the call is reported
        for operand in ["total!", "f()!", "a[0]!", "x1!", "(a)!"] {
            #expect(try await AdvLintHarness.reportsFatal("let r = \(operand)/n + g(fatalError(\"x\"))/2"), "inline after \(operand)")
            #expect(try await AdvLintHarness.reportsFatal("let r = \(operand)\n    /n + g(fatalError(\"x\"))/2"), "line-start after \(operand)")
        }
        // given a prefix ! before a regex literal holding banned-looking text, when linted, then the text is not linted as code
        for shape in ["let ok = !/fatalError(x)/.matches", "if !/fatalError(x)/.matches {}", "let ok = (!/fatalError(x)/.matches)"] {
            #expect(try await status(shape) == 0, "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-02. TASK-368 (accepted ambiguity, pinned so it is a decision). A continued division whose second slash ends the line reads as a regex.
    @Test("KNOWN TASK-368: a continued division whose second slash ends the line hides a banned call")
    func divisionEndingInSlashAtLineEnd() async throws {
        let code = try await status("let r = total\n    /g(fatalError(\"x\"))/\n    2")
        withKnownIssue("operand then line-start /...../ with nothing after it is read as a regex") {
            #expect(code == 1)
        }
    }
}
