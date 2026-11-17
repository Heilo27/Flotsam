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
            .libOs001, "msg with /Users/ryan/secret.txt",
            underlying: UnderlyingErrorInfo(domain: "/Users/ryan/secret.txt", code: -1)
        )
        let record = FlotsamLog.record(for: error)
        #expect(record.publicText == "LIB-OS-001 error")
        #expect(record.privateText.contains("/Users/ryan/secret.txt"))
    }
}

// MARK: - Architecture lint (FR-000-02, FR-000-09)

/// Runs a copy of bin/check-architecture.sh against a throwaway tree holding one fixture file, so the repo is never touched.
private enum AdvLintHarness {
    static var repoRoot: URL {
        // .../Packages/FlotsamCore/Tests/FlotsamBaseTests/<this file>
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    /// Exit status of the lint on a tree containing only `source`.
    static func exitStatus(for source: String) async throws -> Int32 {
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
        try Data((source + "\n").utf8).write(to: base.appendingPathComponent("Fixture.swift"))
        try Data().write(to: root.appendingPathComponent("Packages/FlotsamCore/Package.swift"))

        return try await runProcess("/bin/bash", [root.appendingPathComponent("bin/check-architecture.sh").path]).status
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
