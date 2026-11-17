import Foundation
import Testing
@testable import FlotsamBase

// Worf, FRD-004 FR-004-02 / FRD-000 FR-000-08 (d): an input rejected and shown inline is logged and recorded, and is never
// a HUD or a Notice, and never spends the throttle. Observed at the presenter port, the log sink and the ring buffer;
// expected values are literals.

@MainActor
private struct Rig {
    let clock = ManualClock()
    let presenter = RecordingPresenter()
    let sink = RecordingLogSink()
    let reporter: ErrorReporter

    init() { reporter = ErrorReporter(presenter: presenter, clock: clock, sink: sink) }
}

@MainActor
@Suite struct WorfInlineOriginTests {
    // OC-4301. Red if .inline falls through to showHUD or the Notice board, or is dropped before logging/recording.
    @Test("OC-4301 given an inline ORG-VAL-001, when reported, then it is logged and recorded and neither a HUD nor a Notice appears")
    func inlineIsLoggedRecordedAndSilent() async {
        let rig = Rig()

        await rig.reporter.report(FlotsamError(.orgVal001, "test"), origin: .inline)

        #expect(rig.presenter.huds.isEmpty)
        #expect(rig.presenter.notices.isEmpty)
        #expect(rig.presenter.noticeUpdates == 0)
        #expect(rig.presenter.fatals.isEmpty)
        #expect(rig.sink.records.count == 1)
        #expect(rig.sink.records.first?.headline == "ORG-VAL-001 error")
        let ring = await rig.reporter.recentErrors()
        #expect(ring.map(\.code.rawValue) == ["ORG-VAL-001"])
        #expect(ring.map(\.severity.rawValue) == ["error"])
    }

    // OC-4302. Red if an inline raise passes through throttle.admit: the repeat would be dropped from the log or ring, or the
    // HUD budget would be spent.
    @Test("OC-4302 given the same inline code raised 4 times in a second, then all 4 are logged and recorded")
    func inlineIsNotThrottled() async {
        let rig = Rig()

        for _ in 0..<4 { await rig.reporter.report(FlotsamError(.orgLim001, "test"), origin: .inline) }

        #expect(rig.sink.records.count == 4)
        let ring = await rig.reporter.recentErrors()
        #expect(ring.map(\.code.rawValue) == ["ORG-LIM-001", "ORG-LIM-001", "ORG-LIM-001", "ORG-LIM-001"])
        #expect(rig.presenter.huds.isEmpty)
    }

    // OC-4303. Red if an inline raise stamps the per-code surfacing time or the HUD window: the real HUD right after would
    // be throttled away and the user would see nothing for a failed paste.
    @Test("OC-4303 given 3 inline raises, when the same code then fails user-initiated, then its HUD still shows")
    func inlineDoesNotSpendTheHUDBudget() async {
        let rig = Rig()
        for _ in 0..<3 { await rig.reporter.report(FlotsamError(.orgVal001, "test"), origin: .inline) }
        await rig.reporter.report(FlotsamError(.orgLim002, "test"), origin: .inline)
        await rig.reporter.report(FlotsamError(.orgLim003, "test"), origin: .inline)

        await rig.reporter.report(FlotsamError(.orgVal001, "test"), origin: .userInitiated)

        #expect(rig.presenter.huds.count == 1)
        #expect(rig.presenter.notices.isEmpty)
    }

    // OC-4304. Red if the guard is widened so a non-inline origin stops surfacing too.
    @Test("OC-4304 given the same code user-initiated and background, then a HUD and a Notice still appear")
    func otherOriginsStillSurface() async {
        let rig = Rig()

        await rig.reporter.report(FlotsamError(.orgVal001, "test"), origin: .userInitiated)
        await rig.reporter.report(FlotsamError(.orgLim001, "test"), origin: .background)

        #expect(rig.presenter.huds.count == 1)
        #expect(rig.presenter.notices.map(\.code.rawValue) == ["ORG-LIM-001"])
    }

    // OC-4305. Red if .inline is allowed to swallow a Fatal (the guard moved above the severity switch).
    @Test("OC-4305 given a Fatal raised with the inline origin, then the fatal alert still presents")
    func inlineDoesNotHideFatal() async {
        let rig = Rig()

        await rig.reporter.report(FlotsamError(.stoIo002, "test"), origin: .inline)

        #expect(rig.presenter.fatals.map(\.code.rawValue) == ["STO-IO-002"])
    }
}
