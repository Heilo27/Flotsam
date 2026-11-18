import CoreFoundation
import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

/// TASK-115 (FR-001-01 timer shape) and TASK-116 (AC-001-01 idle cost: 2.5 wake-ups/s).
///
/// Limits, recorded on the tickets: the `Timer` is private, so `tolerance` and its run-loop mode are not readable;
/// the tolerance is pinned through the internal constant, the mode through behaviour (a custom common mode). 0.2 % CPU
/// and 60 MB cannot be measured in a unit test: the wake-up rate and "an idle tick reads only `changeCount`" are the
/// testable parts of that budget.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct GapPollingTests {
    /// OC-115-01. given the poll constants, then 0.5 s with 0.1 s tolerance. Turns red if either number changes.
    @Test("OC-115-01 poll interval is 0.5 s and tolerance 0.1 s")
    func constantsArePinned() {
        #expect(ClipboardCapture.pollInterval == 0.5)
        #expect(ClipboardCapture.pollTolerance == 0.1)
    }

    /// OC-115-02 OC-116-01. given a started capture on an idle board for 2.3 s, when ticks are timed, then they are
    /// at least 0.45 s apart (never faster than 0.5 s minus clock slop), under 1.0 s apart, and the total
    /// wake-up rate is at most 2.5/s. Turns red if the interval is shortened (0.1 s gives ~23 reads) or stretched.
    @Test("OC-115-02 OC-116-01 the real timer ticks about every 0.5 s, at most 2.5 wake-ups per second")
    func realTickRate() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        let started = Date()
        try await Task.sleep(for: .milliseconds(2300))
        let window = Date().timeIntervalSince(started)
        let times = rig.pasteboard.changeCountReadTimes
        let reads = rig.pasteboard.changeCountReads
        await rig.settle()

        let gaps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }.dropFirst()  // drop the launch check's gap
        #expect(reads >= 4 && reads <= 6, "reads in 2.3 s: \(reads)")
        #expect(Double(reads) / window <= 2.5, "wake-ups/s: \(Double(reads) / window)")
        #expect((gaps.min() ?? 0) >= 0.45, "fastest gap \(gaps.min() ?? 0)")
        #expect((gaps.max() ?? 99) <= 1.0, "slowest gap \(gaps.max() ?? 99)")
    }

    /// OC-116-02. given 2.3 s of ticks with nothing copied, then no tick reads pasteboard bytes. Turns red if an
    /// idle tick starts reading content (the cost the AC-001-01 CPU budget forbids).
    @Test("OC-116-02 idle ticks read only the change count, never bytes")
    func idleTicksReadNoBytes() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        try await Task.sleep(for: .milliseconds(1300))
        let reads = rig.pasteboard.changeCountReads
        let bytes = rig.pasteboard.bytesRequested
        await rig.settle()

        #expect(reads >= 2, "control: ticks happened (\(reads))")
        #expect(bytes.isEmpty, "idle ticks requested bytes for \(bytes)")
        #expect(await rig.itemCount() == 0)
    }

    /// OC-115-03. given a run loop in a custom common mode (what AppKit does while a menu is held open), when the
    /// loop runs ONLY in that mode for 1.3 s, then the capture timer still ticks while a control timer registered
    /// for `.default` alone does not; and when the loop returns to `.default` the control fires. Turns red if the
    /// capture timer is added for `.default` instead of `.common`.
    @Test("OC-115-03 the poll keeps ticking while the run loop is in a tracking-style common mode")
    func pollRunsInCommonModes() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        let modeName = "gap.tracking.mode"
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(modeName as CFString))
        rig.capture.start()
        var controlFires = 0
        let control = Timer(timeInterval: 0.2, repeats: true) { _ in controlFires += 1 }
        RunLoop.main.add(control, forMode: .default)
        let readsBefore = rig.pasteboard.changeCountReads

        // when: only the tracking-style mode runs
        Self.spin(mode: RunLoop.Mode(modeName), seconds: 1.3)
        let readsInMode = rig.pasteboard.changeCountReads - readsBefore
        let controlInMode = controlFires

        // then
        #expect(readsInMode >= 2, "capture ticks while tracking: \(readsInMode)")
        #expect(controlInMode == 0, "control: a .default-only timer must not fire in the custom mode (\(controlInMode))")
        Self.spin(mode: .default, seconds: 0.5)
        #expect(controlFires >= 1, "control: the .default timer works when its mode runs")
        control.invalidate()
        await rig.settle()
    }

    nonisolated private static func spin(mode: RunLoop.Mode, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: mode, before: end) }
    }
}
