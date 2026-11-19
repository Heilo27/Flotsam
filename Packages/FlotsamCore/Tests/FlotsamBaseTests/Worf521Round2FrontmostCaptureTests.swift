import Foundation
import Testing
@testable import FlotsamBase

// Worf TASK-521 round 2: attacks on the frontmost-app capture (row f, FR-008-03). The capture is the one value that
// outlives a call, so these pin who owns it: the nil (unknown) case, a passive call arriving between a forcing call and
// its follow-up, two forcing calls, and the order of the capture against the activation request. Each test names the
// product edit that turns it red.

private let flotsamPID: Int32 = 999

@MainActor
private final class ParkedClock: WallClock {
    nonisolated func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    nonisolated func sleep(for duration: Duration) async { await park() }
    private func park() async { await withCheckedContinuation { waiters.append($0) } }
    var parked: Int { waiters.count }
    func releaseAll() {
        let all = waiters
        waiters = []
        for waiter in all { waiter.resume() }
    }
}

/// Like the real adapter, "Flotsam is active" is derived from the frontmost app, so the two cannot disagree. Every
/// read of the frontmost app is logged in the same list as the calls, so order and count are observable.
@MainActor
private final class CoherentWindow: FrontableWindow {
    var log: [String] = []
    var frontmost: Int32?
    var open = true
    init(frontmost: Int32?) { self.frontmost = frontmost }
    var appIsActive: Bool { frontmost == flotsamPID }
    var windowIsOpen: Bool { open }
    var frontmostAppID: Int32? {
        log.append("read")
        return frontmost
    }
    func requestAppActivation() { log.append("request") }
    func orderFrontAndMakeKey() { log.append("front") }
    func forceAppActivation() { log.append("force") }
    var forces: Int { log.filter { $0 == "force" }.count }
}

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<2_000 where !condition() { await Task.yield() }
}

@MainActor
private func drain() async { for _ in 0..<200 { await Task.yield() } }

@MainActor
@Suite("Worf TASK-521 round 2: who owns the captured frontmost app") struct Worf521Round2FrontmostCaptureTests {
    // MARK: nil (frontmost unknown)

    // Red if an unknown app at the call stops counting as "same" at the end (`frontmostAtCall != nil &&` added to the
    // guard): a user who asked for Settings while the system reported no frontmost app would get a window that never
    // comes forward. The user asked for the window and nothing is known to be overridden, so the refusal is escalated.
    @Test("R1: no frontmost app at the call and none at the end of the grace: the refusal is escalated once")
    func nilToNilIsForced() async {
        let clock = ParkedClock(), window = CoherentWindow(frontmost: nil)
        WindowFronting(clock: clock).bringToFront(window)
        await settle { clock.parked == 1 }
        clock.releaseAll()
        await settle { window.forces == 1 }
        await drain()
        #expect(window.forces == 1)
        #expect(window.log.filter { $0 == "front" }.count == 2, "ordered front again after the force")
    }

    // Red if an unknown app at the call is treated as a wildcard AND the active check is dropped (two edits: either
    // guard alone still protects this case, which is the point: it is defended twice).
    @Test("R2: no frontmost app at the call and Flotsam is frontmost at the end: nothing is forced")
    func nilToFlotsamIsNotForced() async {
        let clock = ParkedClock(), window = CoherentWindow(frontmost: nil)
        WindowFronting(clock: clock).bringToFront(window)
        await settle { clock.parked == 1 }
        window.frontmost = flotsamPID
        clock.releaseAll()
        await drain()
        #expect(window.forces == 0)
        #expect(window.log.filter { $0 == "front" }.count == 1)
    }

    // Red if an unknown app at the end is let through as "no objection" (`now == nil || now == captured` in the guard):
    // the window server reporting nothing mid-switch would then be read as "the refusal stands" and forced over.
    @Test("R3: the app known at the call went unknown at the end: the user moved on to nothing we can see, so not forced")
    func knownToNilIsNotForced() async {
        let clock = ParkedClock(), window = CoherentWindow(frontmost: 100)
        WindowFronting(clock: clock).bringToFront(window)
        await settle { clock.parked == 1 }
        window.frontmost = nil
        clock.releaseAll()
        await drain()
        #expect(window.forces == 0)
    }

    // MARK: a passive call between a capture and its follow-up

    // Red if the capture becomes shared state refreshed by every call, passive ones included (a stored `lastFrontmost`
    // assigned before `guard forcing`, read by the follow-up): the passive call, made while the user is in app 200,
    // would re-base the comparison to 200 and the follow-up would force over a user who has moved on.
    @Test("R4: a passive show made after the user switched apps does not re-base the user's pending follow-up")
    func passiveCallDoesNotRebaseCapture() async {
        let clock = ParkedClock(), window = CoherentWindow(frontmost: 100)
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)  // the user's open, over app 100
        await settle { clock.parked == 1 }
        window.frontmost = 200  // the user moves on
        fronting.bringToFront(window, forcing: false)  // the launch-style show arrives
        clock.releaseAll()
        await drain()
        #expect(window.forces == 0)
    }

    // The mirror: red if the passive call's capture replaces the user's (the follow-up would compare 100 with 200).
    @Test("R5: a passive show in between, and the user is back in the original app at the end: still forced, once")
    func passiveCallThenBackInOriginalAppIsForced() async {
        let clock = ParkedClock(), window = CoherentWindow(frontmost: 100)
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)
        await settle { clock.parked == 1 }
        window.frontmost = 200
        fronting.bringToFront(window, forcing: false)
        window.frontmost = 100
        clock.releaseAll()
        await settle { window.forces == 1 }
        await drain()
        #expect(window.forces == 1)
    }

    // MARK: two forcing calls

    // Red if the first capture survives the second call (kept per window, or "either captured app matches" in the
    // guard): the user who asked again from app 200 and then went back to 100 would be forced over.
    @Test("R6: the second forcing call's capture replaces the first's: judged against 200, not 100")
    func secondCaptureReplacesFirst() async {
        let clock = ParkedClock(), window = CoherentWindow(frontmost: 100)
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)
        await settle { clock.parked == 1 }
        window.frontmost = 200
        fronting.bringToFront(window)  // asked again, now from app 200
        await settle { clock.parked == 2 }
        window.frontmost = 100  // matches only the first capture
        clock.releaseAll()
        await drain()
        #expect(window.forces == 0)
    }

    // MARK: sampling model

    // Red if the capture moves after `requestAppActivation()`: an accepted request makes Flotsam frontmost, so a
    // capture taken after it would hold Flotsam's pid, and a user who then returned to the original app inside the
    // grace would no longer be judged against it.
    @Test("R7: the frontmost app is read exactly once, before the activation request, and once more when the grace ends")
    func capturedBeforeRequestAndReadTwice() async {
        let clock = ParkedClock(), window = CoherentWindow(frontmost: 100)
        WindowFronting(clock: clock).bringToFront(window)
        #expect(window.log == ["read", "request", "front"], "capture first, then request, then show")
        await settle { clock.parked == 1 }
        clock.releaseAll()
        await settle { window.forces == 1 }
        await drain()
        #expect(window.log == ["read", "request", "front", "read", "force", "front"], "one read at the end, none more")
    }

    // The honest account of "switch away and back inside the grace": WindowFronting samples at two instants only (the
    // call and the end of the grace), with nothing observing in between, so the switch is invisible and the outcome is
    // the same as no switch at all. This pins that model: a version that polled or latched during the grace would read
    // more than twice, and would be a different (and more expensive) rule than FR-008-03 states.
    @Test("R8: a switch away and back inside the grace is invisible by design: two reads, forced, no polling")
    func noPollingDuringGrace() async {
        let clock = ParkedClock(), window = CoherentWindow(frontmost: 100)
        WindowFronting(clock: clock).bringToFront(window)
        await settle { clock.parked == 1 }
        window.frontmost = 200
        window.frontmost = 100
        await drain()
        #expect(window.log.filter { $0 == "read" }.count == 1, "nothing read the frontmost app during the grace")
        clock.releaseAll()
        await settle { window.forces == 1 }
        await drain()
        #expect(window.log.filter { $0 == "read" }.count == 2)
        #expect(window.forces == 1)
    }
}
