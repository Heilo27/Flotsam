import Foundation
import Testing
@testable import FlotsamBase

/// TASK-417 / FR-000-08 / FR-001-18: clearing a code's Notices restarts that code's 60 s throttle. Observed at the
/// presenter port (what the user would see). Expected values are literals.
@MainActor
@Suite struct Worf417ThrottleResetTests {
    private func rig() -> (ManualClock, RecordingPresenter, ErrorReporter) {
        let clock = ManualClock(), presenter = RecordingPresenter()
        return (clock, presenter, ErrorReporter(presenter: presenter, clock: clock, sink: RecordingLogSink()))
    }

    /// OC-417-W1. given CAP-OS-001 surfaced, cleared, and raised again 10 s later, when reported, then it shows again
    /// (one Notice, a fresh surfacing); a DIFFERENT code's surfacing is untouched by the clear, so its repeat at +10 s
    /// is still throttled. Red if clearNotices(code:) stops resetting the throttle, or resets every code's.
    @Test("OC-417-W1 clearNotices(code:) restarts only that code's throttle")
    func clearRestartsOnlyThatCode() async {
        let (clock, presenter, reporter) = rig()
        await reporter.report(FlotsamError(.capOs001, "test"), origin: .background)
        await reporter.report(FlotsamError(.capLim003, "test", context: [.count: .int(501)]), origin: .background)
        #expect(presenter.notices.count == 2)

        await reporter.clearNotices(code: .capOs001)
        #expect(presenter.notices.map(\.code.rawValue) == ["CAP-LIM-003"])

        clock.advance(by: 10)
        await reporter.report(FlotsamError(.capOs001, "test"), origin: .background)
        await reporter.report(FlotsamError(.capLim003, "test", context: [.count: .int(501)]), origin: .background)
        #expect(presenter.notices.map(\.code.rawValue) == ["CAP-OS-001", "CAP-LIM-003"], "re-raise after clear shows; the other code stays throttled")
    }

    /// OC-417-W2. given CAP-OS-001 surfaced then "Dismiss all", when it recurs 10 s later, then it stays throttled:
    /// FR-000-08 says Dismiss all does not clear the throttle. And clearing a code with no Notice still restarts it
    /// (owners may call on every recovery). Red if dismissAllNotices starts resetting the throttle.
    @Test("OC-417-W2 Dismiss all keeps the throttle; clear with no Notice still restarts it")
    func dismissAllKeepsThrottle() async {
        let (clock, presenter, reporter) = rig()
        await reporter.report(FlotsamError(.capOs001, "test"), origin: .background)
        await reporter.dismissAllNotices()
        clock.advance(by: 10)
        await reporter.report(FlotsamError(.capOs001, "test"), origin: .background)
        #expect(presenter.notices.isEmpty, "Dismiss all must not clear the throttle")

        await reporter.clearNotices(code: .capOs001)   // no Notice on the board
        await reporter.report(FlotsamError(.capOs001, "test"), origin: .background)
        #expect(presenter.notices.map(\.code.rawValue) == ["CAP-OS-001"])
        let ring = await reporter.recentErrors()
        #expect(ring.count == 3, "throttled raises are still recorded")
    }
}
