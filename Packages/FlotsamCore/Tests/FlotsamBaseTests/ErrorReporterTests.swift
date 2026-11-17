import Foundation
import Testing
@testable import FlotsamBase

// FRD-000 reporter behaviour (FR-000-08, FR-000-13). Observed at the presenter port (what the user would see) and the
// reporter's ring buffer; expected values are literals. Time is a ManualClock starting at 1_800_000_000.

private let t0 = 1_800_000_000.0

/// Inputs only: the safe context a raise of `code` needs so its message resolves (the placeholder codes fall back to
/// SYS-INT-001 text without it). Not an expectation.
private func raise(_ code: ErrorCode) -> FlotsamError {
    switch code {
    case .capLim001, .sspLim001: FlotsamError(code, "test", context: [.limitBytes: .bytes(26_214_400)])
    case .capLim003: FlotsamError(code, "test", context: [.count: .int(501)])
    default: FlotsamError(code, "test")
    }
}

@MainActor
private struct Rig {
    let clock = ManualClock()
    let presenter = RecordingPresenter()
    let sink = RecordingLogSink()
    let reporter: ErrorReporter

    init() { reporter = ErrorReporter(presenter: presenter, clock: clock, sink: sink) }
}

@MainActor
@Suite struct ErrorReporterTests {
    // MARK: OC-0011, OC-0012

    /// OC-0011. given a Warning, Error and Info raise, when reported, then no fatal alert is presented; given two
    /// Fatal raises, then each presents (unthrottled) and each is recorded.
    @Test("OC-0011 only Fatal presents the fatal alert, and it is never throttled")
    func fatalOnlyForFatal() async {
        let rig = Rig()
        await rig.reporter.report(raise(.capOs001), origin: .background)
        await rig.reporter.report(raise(.libOs001), origin: .userInitiated)
        await rig.reporter.report(raise(.capPol001), origin: .background)
        #expect(rig.presenter.fatals.isEmpty)

        await rig.reporter.report(raise(.stoIo002), origin: .background)
        await rig.reporter.report(raise(.stoIo002), origin: .background)
        #expect(rig.presenter.fatals.count == 2, "second identical fatal must not be throttled")
        #expect(rig.presenter.fatals.map(\.code.rawValue) == ["STO-IO-002", "STO-IO-002"])
        #expect(rig.presenter.huds.count == 1, "only the LIB-OS-001 HUD; fatal draws no HUD")
        #expect(rig.presenter.notices.count == 1, "only the CAP-OS-001 notice; fatal draws no notice")
        let ring = await rig.reporter.recentErrors()
        #expect(ring.map(\.code.rawValue) == ["CAP-OS-001", "LIB-OS-001", "STO-IO-002", "STO-IO-002"])
        #expect(ring.map(\.severity.rawValue) == ["warning", "error", "fatal", "fatal"])
    }

    /// OC-0012 (reporter half). given a user-initiated LIB-OS-001, when reported, then one HUD with the catalogue text
    /// and no notice, no badge change.
    @Test("OC-0012 user-initiated LIB-OS-001 shows a HUD with the exact text and no notice")
    func userInitiatedShowsHUD() async {
        let rig = Rig()
        await rig.reporter.report(raise(.libOs001), origin: .userInitiated)
        #expect(rig.presenter.huds == ["Couldn't paste into that app. The item is on your clipboard; press ⌘V."])
        #expect(rig.presenter.notices.isEmpty)
        #expect(rig.presenter.noticeUpdates == 0)
    }

    // MARK: OC-0022, OC-0023, OC-0026

    /// OC-0022. given 10 identical background warnings within 30 s, then 1 notice, 0 HUDs, the ring holds all 10.
    @Test("OC-0022 ten identical background warnings in 30 s give one notice, ten ring entries")
    func identicalBackgroundWarningsCoalesce() async {
        let rig = Rig()
        for _ in 0..<10 {
            await rig.reporter.report(raise(.capLim001), origin: .background)
            rig.clock.advance(by: 3)
        }
        #expect(rig.presenter.notices.count == 1)
        #expect(rig.presenter.noticeUpdates == 1)
        #expect(rig.presenter.huds.isEmpty)
        let ring = await rig.reporter.recentErrors()
        #expect(ring.count == 10, "throttled occurrences are still recorded")
        #expect(Set(ring.map(\.code.rawValue)) == ["CAP-LIM-001"])
        #expect(ring.map(\.timestamp.timeIntervalSince1970) == (0..<10).map { t0 + Double($0) * 3 })
    }

    /// OC-0023. given a code surfaced at +0, when it recurs at +40 and +59 it stays suppressed, and at +61 it surfaces
    /// again: the window runs from the last SURFACED occurrence, so the suppressed +40/+59 did not restart it.
    @Test("OC-0023 window is measured from the last surfaced occurrence")
    func windowMeasuredFromLastSurfaced() async {
        let rig = Rig()
        await rig.reporter.report(raise(.capOs001), origin: .background)
        rig.clock.advance(by: 40)
        await rig.reporter.report(raise(.capOs001), origin: .background)
        rig.clock.advance(by: 19)
        await rig.reporter.report(raise(.capOs001), origin: .background)
        #expect(rig.presenter.notices.count == 1, "+59 s must still be suppressed")
        rig.clock.advance(by: 2)
        await rig.reporter.report(raise(.capOs001), origin: .background)
        #expect(rig.presenter.notices.count == 2, "+61 s from the first surfaced occurrence must surface")
        #expect(rig.presenter.notices.map(\.date.timeIntervalSince1970) == [t0 + 61, t0])
        let ring = await rig.reporter.recentErrors()
        #expect(ring.count == 4)
    }

    /// OC-0026. given SSP-LIM-001 from the background pickup, when reported, then no HUD and one notice with the text.
    @Test("OC-0026 background SSP-LIM-001 is a notice with the limit shown, never a HUD")
    func backgroundScreenshotLimitIsNotice() async {
        let rig = Rig()
        await rig.reporter.report(raise(.sspLim001), origin: .background)
        #expect(rig.presenter.huds.isEmpty)
        #expect(rig.presenter.notices.map(\.message) == ["A screenshot was too large to import (over 25 MB)."])
        #expect(rig.presenter.notices.map(\.code.rawValue) == ["SSP-LIM-001"])
    }

    // MARK: OC-0024

    /// OC-0024. given 5 distinct user-initiated codes in the same minute, then exactly the first 3 show HUDs; the other
    /// 2 are still recorded; after the minute a 4th HUD can show; a background notice is not counted against the cap.
    @Test("OC-0024 at most three HUDs per minute across codes")
    func hudCapThreePerMinute() async {
        let rig = Rig()
        for code in [ErrorCode.libOs001, .orgVal001, .trgVal001, .shfOs001, .setOs001] {
            await rig.reporter.report(raise(code), origin: .userInitiated)
            rig.clock.advance(by: 1)
        }
        #expect(rig.presenter.huds == [
            "Couldn't paste into that app. The item is on your clipboard; press ⌘V.",
            "Tag names must be 1 to 32 characters and unique.",
            "Triggers start with a symbol (like ;), have 2 to 24 characters and contain no spaces.",
        ])
        let ring = await rig.reporter.recentErrors()
        #expect(ring.count == 5, "suppressed HUDs are still recorded")

        await rig.reporter.report(raise(.capOs001), origin: .background)
        #expect(rig.presenter.notices.count == 1, "background notices are outside the HUD cap")

        rig.clock.advance(by: 61)
        await rig.reporter.report(raise(.shfOs001), origin: .userInitiated)
        #expect(rig.presenter.huds.count == 4)
        #expect(rig.presenter.huds.last == "Couldn't drag that item out. Try again or paste it from the Library.")
    }

    // MARK: Throttle window boundary (mutation gate M3c, FR-000-08)

    /// OC-0023 boundary. given a code surfaced at +0, when it recurs 59 s later it is suppressed and 60 s later it
    /// surfaces. FR-000-08 says "at most once per 60 s" without naming the exact second; the reporter treats a 60 s old
    /// surfacing as expired, and this pins that so an off-by-one on the window turns red. [Spec ambiguity reported.]
    @Test("OC-0023 per-code window: suppressed at 59 s, surfaces at exactly 60 s", arguments: [(59.0, 1), (60.0, 2)])
    func perCodeWindowBoundary(gap: Double, noticesAfter: Int) async {
        let rig = Rig()
        await rig.reporter.report(raise(.capOs001), origin: .background)
        rig.clock.advance(by: gap)
        await rig.reporter.report(raise(.capOs001), origin: .background)
        #expect(rig.presenter.notices.count == noticesAfter)
    }

    /// OC-0024 boundary. given 3 HUDs at +0, when a 4th HUD (a new code) is raised 59 s later it is suppressed and
    /// 60 s later it shows: the HUD cap is per rolling minute.
    @Test("OC-0024 HUD cap: 4th HUD suppressed at 59 s, shown at exactly 60 s", arguments: [(59.0, 3), (60.0, 4)])
    func hudWindowBoundary(gap: Double, hudsAfter: Int) async {
        let rig = Rig()
        for code in [ErrorCode.libOs001, .orgVal001, .trgVal001] {
            await rig.reporter.report(raise(code), origin: .userInitiated)
        }
        #expect(rig.presenter.huds.count == 3, "precondition: the cap is reached")
        rig.clock.advance(by: gap)
        await rig.reporter.report(raise(.shfOs001), origin: .userInitiated)
        #expect(rig.presenter.huds.count == hudsAfter)
    }

    // MARK: OC-0027

    private static let twelve: [ErrorCode] = [
        .capPrm001, .capOs001, .capLim001, .capLim003, .sspPrm001, .sspIo001,
        .sspIo003, .sspLim001, .sspOs001, .libDat001, .trgVal005, .trgOs003,
    ]

    /// OC-0027. given N distinct background warnings, when the board is read, then at most 10 remain, newest first,
    /// the oldest dropped. Boundaries 10 (all kept), 11 (1 dropped), 12 (2 dropped).
    @Test("OC-0027 notices cap at 10, newest first", arguments: [
        (10, ["LIB-DAT-001", "SSP-OS-001", "SSP-LIM-001", "SSP-IO-003", "SSP-IO-001", "SSP-PRM-001", "CAP-LIM-003", "CAP-LIM-001", "CAP-OS-001", "CAP-PRM-001"]),
        (11, ["TRG-VAL-005", "LIB-DAT-001", "SSP-OS-001", "SSP-LIM-001", "SSP-IO-003", "SSP-IO-001", "SSP-PRM-001", "CAP-LIM-003", "CAP-LIM-001", "CAP-OS-001"]),
        (12, ["TRG-OS-003", "TRG-VAL-005", "LIB-DAT-001", "SSP-OS-001", "SSP-LIM-001", "SSP-IO-003", "SSP-IO-001", "SSP-PRM-001", "CAP-LIM-003", "CAP-LIM-001"]),
    ])
    func noticesCapAtTen(raised: Int, expectedNewestFirst: [String]) async {
        let rig = Rig()
        for code in Self.twelve.prefix(raised) {
            await rig.reporter.report(raise(code), origin: .background)
            rig.clock.advance(by: 1)
        }
        #expect(rig.presenter.notices.map(\.code.rawValue) == expectedNewestFirst)
        let ring = await rig.reporter.recentErrors()
        #expect(ring.count == raised, "the ring keeps all \(raised); only the notice list is capped")
    }

    /// OC-0027 text. given the 12th raise, then its notice carries its catalogue text.
    @Test("OC-0027 newest notice carries its catalogue text")
    func newestNoticeText() async {
        let rig = Rig()
        for code in Self.twelve {
            await rig.reporter.report(raise(code), origin: .background)
            rig.clock.advance(by: 1)
        }
        #expect(rig.presenter.notices.first?.message == "Typed triggers were paused by macOS and have been restarted.")
    }

    // MARK: OC-0028, OC-0029, OC-0030, OC-0044

    /// OC-0028. given 3 notices, when Dismiss all runs, then the list is empty (badge clears) and the ring is unchanged.
    @Test("OC-0028 dismiss all empties the notices and leaves the ring intact")
    func dismissAll() async {
        let rig = Rig()
        for code in [ErrorCode.capPrm001, .capOs001, .libDat001] {
            await rig.reporter.report(raise(code), origin: .background)
        }
        #expect(rig.presenter.notices.count == 3)
        let before = await rig.reporter.recentErrors()
        await rig.reporter.dismissAllNotices()
        #expect(rig.presenter.notices.isEmpty)
        #expect(rig.presenter.noticeUpdates == 4)
        let after = await rig.reporter.recentErrors()
        #expect(after == before)
        #expect(after.count == 3)
    }

    /// OC-0028 follow-up. given 3 notices dismissed, when a new background notice arrives, then the list holds only
    /// the new one: dismissal emptied the reporter's own list, not just the screen it last drew.
    @Test("OC-0028 after dismiss all, the next notice is the only one listed")
    func dismissAllClearsTheReportersList() async {
        let rig = Rig()
        for code in [ErrorCode.capPrm001, .capOs001, .libDat001] {
            await rig.reporter.report(raise(code), origin: .background)
        }
        await rig.reporter.dismissAllNotices()
        await rig.reporter.report(raise(.trgOs003), origin: .background)
        #expect(rig.presenter.notices.count == 1)
        #expect(rig.presenter.notices.map(\.code.rawValue) == ["TRG-OS-003"])
    }

    /// OC-0029 / OC-0030 / OC-0044. given errors raised on one reporter, when a fresh reporter is created (a quit and
    /// relaunch), then it has no notices and an empty ring: nothing survives except in memory.
    @Test("OC-0029 OC-0030 OC-0044 a fresh reporter starts with no notices and an empty ring")
    func freshReporterIsEmpty() async {
        let first = Rig()
        for code in [ErrorCode.capPrm001, .libOs001, .stoDb001] {
            await first.reporter.report(raise(code), origin: .background)
        }
        #expect(await first.reporter.recentErrors().count == 3)

        let second = Rig()
        #expect(await second.reporter.recentErrors().isEmpty)
        #expect(second.presenter.notices.isEmpty)
        #expect(second.presenter.noticeUpdates == 0)
    }

    // MARK: OC-0043

    /// OC-0043. given N Error raises 61 s apart, when the ring is read, then it holds min(N,100), oldest dropped first,
    /// still oldest-first. N = 99, 100, 101, 105.
    @Test("OC-0043 ring holds the last 100, oldest first", arguments: [
        (99, 99, 1_800_000_000.0, 1_800_005_978.0),
        (100, 100, 1_800_000_000.0, 1_800_006_039.0),
        (101, 100, 1_800_000_061.0, 1_800_006_100.0),
        (105, 100, 1_800_000_305.0, 1_800_006_344.0),
    ])
    func ringKeepsLastHundred(raised: Int, expectedCount: Int, expectedFirst: Double, expectedLast: Double) async {
        let rig = Rig()
        for _ in 0..<raised {
            await rig.reporter.report(raise(.stoDb001), origin: .background)
            rig.clock.advance(by: 61)
        }
        let ring = await rig.reporter.recentErrors()
        #expect(ring.count == expectedCount)
        #expect(ring.first?.timestamp.timeIntervalSince1970 == expectedFirst)
        #expect(ring.last?.timestamp.timeIntervalSince1970 == expectedLast)
        let times = ring.map(\.timestamp.timeIntervalSince1970)
        #expect(times == times.sorted(), "oldest first")
    }

    // MARK: OC-0052

    /// OC-0052. given STO-DB-001 raised by a user action and by a background job, then severity is Error both times
    /// and the log level is `.error` (16) either way; only the surface differs.
    @Test("OC-0052 STO-DB-001 has one severity regardless of origin")
    func severityIndependentOfOrigin() async {
        let user = Rig()
        await user.reporter.report(raise(.stoDb001), origin: .userInitiated)
        let background = Rig()
        await background.reporter.report(raise(.stoDb001), origin: .background)

        #expect(await user.reporter.recentErrors().map(\.severity.rawValue) == ["error"])
        #expect(await background.reporter.recentErrors().map(\.severity.rawValue) == ["error"])
        #expect(background.presenter.notices.map(\.severity.rawValue) == ["error"])
        #expect(FlotsamLog.level(for: raise(.stoDb001).severity).rawValue == 16)
        #expect(user.presenter.huds == ["Flotsam couldn't save your history. Free up disk space and try again."])
        #expect(background.presenter.huds.isEmpty)
    }

    // MARK: OC-0066, OC-0067, OC-0068

    /// OC-0066. given a Warning, 150 CAP-POL-001 Info, then an Error, then the ring is exactly [Warning, Error].
    @Test("OC-0066 Info raises are never recorded: W, 150 Info, E gives exactly two entries")
    func infoNeverRecorded() async {
        let rig = Rig()
        await rig.reporter.report(raise(.capOs001), origin: .background)
        for _ in 0..<150 { await rig.reporter.report(raise(.capPol001), origin: .background) }
        await rig.reporter.report(raise(.stoDb001), origin: .background)
        let ring = await rig.reporter.recentErrors()
        #expect(ring.map(\.code.rawValue) == ["CAP-OS-001", "STO-DB-001"])
        #expect(ring.map(\.severity.rawValue) == ["warning", "error"])
    }

    /// OC-0067. given a full ring of 100 Errors, when 500 Info raises follow, then all 100 Errors are still there.
    @Test("OC-0067 500 Info raises do not evict 100 Errors")
    func infoDoesNotEvict() async {
        let rig = Rig()
        for _ in 0..<100 {
            await rig.reporter.report(raise(.libOs001), origin: .background)
            rig.clock.advance(by: 1)
        }
        for _ in 0..<500 { await rig.reporter.report(raise(.trgPol001), origin: .background) }
        let ring = await rig.reporter.recentErrors()
        #expect(ring.count == 100)
        #expect(ring.first?.timestamp.timeIntervalSince1970 == t0)
        #expect(Set(ring.map(\.code.rawValue)) == ["LIB-OS-001"])
    }

    /// OC-0068. given only Info raises, then the ring is empty, no HUD, no notice, no badge update.
    @Test("OC-0068 Info-only history leaves the ring and every surface empty")
    func infoOnlyIsEmpty() async {
        let rig = Rig()
        for code in [ErrorCode.capPol001, .capPol002, .trgPol001, .stoPol001] {
            await rig.reporter.report(raise(code), origin: .userInitiated)
            await rig.reporter.report(raise(code), origin: .background)
        }
        #expect(await rig.reporter.recentErrors().isEmpty)
        #expect(rig.presenter.huds.isEmpty)
        #expect(rig.presenter.notices.isEmpty)
        #expect(rig.presenter.noticeUpdates == 0)
        #expect(rig.presenter.fatals.isEmpty)
    }
}

// MARK: - Log contract (FR-000-04, FR-000-09, FR-000-10, FR-000-11): what `report` writes to the log sink

/// One raised code with its literal expectations: the headline `"<code> <severity>"`, the OSLog level raw value
/// (Info 1, Default 0, Error 16, Fault 17) and the category.
struct LoggedCase: Sendable, CustomTestStringConvertible {
    let code: ErrorCode
    let headline: String
    let level: UInt8
    let category: String
    var testDescription: String { headline }
}

let loggedCases: [LoggedCase] = [
    LoggedCase(code: .capPol001, headline: "CAP-POL-001 info", level: 1, category: "capture"),
    LoggedCase(code: .capLim001, headline: "CAP-LIM-001 warning", level: 0, category: "capture"),
    LoggedCase(code: .capIo001, headline: "CAP-IO-001 error", level: 16, category: "capture"),
    LoggedCase(code: .stoIo002, headline: "STO-IO-002 fatal", level: 17, category: "storage"),
]

@MainActor
@Suite struct ErrorReporterLogTests {
    /// OC-0040, OC-0013, OC-0014. given one raise of a code of each severity (Info included), when reported, then the
    /// sink receives exactly one record for it with that code and severity in the clear. Red if the log call is
    /// removed, or Info is skipped.
    @Test("OC-0040 OC-0013 OC-0014 every severity, Info included, writes exactly one log record", arguments: loggedCases)
    func everySeverityWritesOneRecord(logged: LoggedCase) async throws {
        let rig = Rig()
        await rig.reporter.report(raise(logged.code), origin: .background)
        let records = rig.sink.records
        #expect(records.count == 1)
        #expect(records.filter { $0.headline == logged.headline }.count == 1)
    }

    /// OC-0032, OC-0013. given each severity reported through the reporter, then the record carries the FR-000-09
    /// level: Info `.info`, Warning notice, Error `.error`, Fatal `.fault`, in the module's category.
    @Test("OC-0032 OC-0013 the record's level and category follow the code's severity and module", arguments: loggedCases)
    func recordLevelAndCategory(logged: LoggedCase) async throws {
        let rig = Rig()
        await rig.reporter.report(raise(logged.code), origin: .background)
        let record = try #require(rig.sink.records.first { $0.headline == logged.headline })
        #expect(record.level.rawValue == logged.level)
        #expect(record.category.rawValue == logged.category)
    }

    /// OC-0013, OC-0014, OC-0040, OC-0033, OC-0035 (unit-reachable part). given an error carrying a static message, a
    /// private item id, a bundle id, a public byte size and a system cause, when reported, then the public text is
    /// the code, severity and byte size only, and the private text holds the id, bundle id, message and cause
    /// `domain:code`. Red if message, cause or private context moves into the public text, or the cause loses its
    /// domain.
    @Test("OC-0013 OC-0035 user data, message and cause domain:code appear only in the private text")
    func privacySplitAtTheSink() async {
        let rig = Rig()
        let itemId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let bundle = BundleIdentifier("com.flotsamtest.markbid1")!
        let error = FlotsamError(
            .capIo001, "marker-message-q7",
            context: [.itemId: .id(itemId), .bundleId: .bundleId(bundle), .byteSize: .bytes(12)],
            underlying: UnderlyingErrorInfo(domain: "NSCocoaErrorDomain", code: 640)
        )
        await rig.reporter.report(error, origin: .background)
        let records = rig.sink.records
        #expect(records.count == 1)
        guard let record = records.first else { return }
        #expect(record.publicText == "CAP-IO-001 error byteSize=12B")
        #expect(record.privateText == "bundleId=com.flotsamtest.markbid1 itemId=6F9619FF-8B86-D011-B42D-00C04FC964FF marker-message-q7 NSCocoaErrorDomain:640")
        for secret in ["markbid1", "6F9619FF", "marker-message-q7", "NSCocoaErrorDomain", "640"] {
            #expect(!record.publicText.contains(secret), "\(secret) leaked into the public text")
        }
    }

    /// OC-0035 negative. given an error with no cause and no context, then the private text carries only the message
    /// and no stray `domain:code` separator.
    @Test("OC-0035 an error with no cause logs no cause text")
    func noCauseNoCauseText() async {
        let rig = Rig()
        await rig.reporter.report(FlotsamError(.capIo001, "plain-message"), origin: .background)
        let records = rig.sink.records
        #expect(records.count == 1)
        #expect(records.first?.publicText == "CAP-IO-001 error")
        #expect(records.first?.cause == nil)
        #expect(records.first?.privateText.contains(":") == false)
        #expect(records.first?.privateText.contains("plain-message") == true)
    }

    /// AC-000-04, OC-0040. given the same background Warning raised three times within 6 s, then one Notice shows (two
    /// are throttled) and the sink still has three records.
    @Test("AC-000-04 a throttled occurrence is still logged")
    func throttledBackgroundOccurrencesAreLogged() async {
        let rig = Rig()
        for _ in 0..<3 {
            await rig.reporter.report(raise(.capLim001), origin: .background)
            rig.clock.advance(by: 2)
        }
        #expect(rig.presenter.notices.count == 1, "precondition: two of the three were throttled")
        #expect(rig.sink.records.count == 3)
        #expect(rig.sink.records.filter { $0.headline == "CAP-LIM-001 warning" }.count == 3)
    }

    /// AC-000-04, OC-0040. given four different user-initiated Errors inside one minute, then the fourth HUD is
    /// suppressed by the cap, but all four codes are logged, the suppressed one included.
    @Test("AC-000-04 a HUD suppressed by the three-per-minute cap is still logged")
    func capSuppressedHUDIsLogged() async {
        let rig = Rig()
        let codes: [ErrorCode] = [.libOs001, .libIo001, .libDat001, .shfOs001]
        for code in codes {
            await rig.reporter.report(raise(code), origin: .userInitiated)
            rig.clock.advance(by: 1)
        }
        #expect(rig.presenter.huds.count == 3, "precondition: the fourth HUD was suppressed")
        #expect(rig.sink.records.count == 4)
        #expect(rig.sink.records.filter { $0.headline == "SHF-OS-001 error" }.count == 1, "the suppressed SHF-OS-001 is logged")
    }

    /// OC-0040. given one Warning, one Error and one Fatal raised in a session, then each of the three codes has
    /// exactly one record, and nothing else was logged.
    @Test("OC-0040 a Warning, an Error and a Fatal each have a record")
    func sessionOfThreeSeverities() async {
        let rig = Rig()
        await rig.reporter.report(raise(.capLim001), origin: .background)
        await rig.reporter.report(raise(.capIo001), origin: .background)
        await rig.reporter.report(raise(.stoIo002), origin: .background)
        let headlines = rig.sink.records.map(\.headline)
        #expect(headlines.count == 3)
        #expect(Set(headlines) == ["CAP-LIM-001 warning", "CAP-IO-001 error", "STO-IO-002 fatal"])
    }
}
