import Foundation
import Testing
@testable import FlotsamBase

// TASK-521 rows f and g (OC-8024 / FR-008-03).
// Row f: the forced activation must not override a user who switched apps inside the grace. `WindowFronting` reads the
// frontmost app when it is asked to show the window and forces only if that same app is still frontmost when the grace
// ends (a refused request leaves it there); a third app means the user moved on and nothing is forced.
// Row g: a miniaturized window ignores the ordering calls and reports `isVisible == false`, so the adapter must
// deminiaturize it first and count it as open. The adapter is AppKit and lives in the App target, so row g is pinned by
// a scan of its source; the real behaviour is the live matrix's.

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

@MainActor
private final class AppWindow: FrontableWindow {
    var log: [String] = []
    var frontmost: Int32?
    init(frontmost: Int32?) { self.frontmost = frontmost }
    var appIsActive: Bool { false }
    var windowIsOpen: Bool { true }
    var frontmostAppID: Int32? { frontmost }
    func requestAppActivation() { log.append("request") }
    func orderFrontAndMakeKey() { log.append("front") }
    func forceAppActivation() { log.append("force") }
}

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<2_000 where !condition() { await Task.yield() }
}

@MainActor
private func drain() async { for _ in 0..<100 { await Task.yield() } }

@MainActor
@Suite("TASK-521 row f: the forced activation never overrides a user who moved to another app") struct Task521FrontmostAppTests {
    // Red if the follow-up stops comparing the frontmost app (the guard's last term removed).
    @Test("the user switched to a third app inside the grace: nothing is forced and the window is not ordered front again")
    func thirdAppIsLeftAlone() async {
        let clock = ParkedClock(), window = AppWindow(frontmost: 100)
        WindowFronting(clock: clock).bringToFront(window)
        await settle { clock.parked == 1 }
        window.frontmost = 200
        clock.releaseAll()
        await drain()
        #expect(window.log == ["request", "front"])
    }

    // Red if the follow-up never forces (the comparison inverted, or the term made always false).
    @Test("the app that was frontmost at the call is still frontmost when the grace ends: the refusal is escalated")
    func sameAppIsForced() async {
        let clock = ParkedClock(), window = AppWindow(frontmost: 100)
        WindowFronting(clock: clock).bringToFront(window)
        await settle { clock.parked == 1 }
        clock.releaseAll()
        await settle { window.log.count == 4 }
        #expect(window.log == ["request", "front", "force", "front"])
    }

    // Red if the frontmost app is read when the grace begins to run rather than when it ends (a switch and a switch back
    // would not matter) or latched on a change: the rule is judged on how things stand at the end of the grace.
    @Test("a switch away and back inside the grace is judged at the end of it: forced")
    func switchAwayAndBackIsForced() async {
        let clock = ParkedClock(), window = AppWindow(frontmost: 100)
        WindowFronting(clock: clock).bringToFront(window)
        await settle { clock.parked == 1 }
        window.frontmost = 200
        window.frontmost = 100
        clock.releaseAll()
        await settle { window.log.contains("force") }
        #expect(window.log == ["request", "front", "force", "front"])
    }

    // Red if the captured app is taken at the follow-up's start (inside the Task) instead of at the call: a switch made
    // before the Task body runs would then be taken as the "original" app and forced over.
    @Test("the frontmost app is captured at the call, before the follow-up task has run")
    func capturedAtCallTime() async {
        let clock = ParkedClock(), window = AppWindow(frontmost: 100)
        WindowFronting(clock: clock).bringToFront(window)
        window.frontmost = 200  // no await since the call: the follow-up task has not started
        await settle { clock.parked == 1 }
        clock.releaseAll()
        await drain()
        #expect(window.log == ["request", "front"])
    }

    // Red if an unknown frontmost app at the call is treated as "no constraint".
    @Test("no frontmost app known at the call and one appears inside the grace: the user moved on, nothing is forced")
    func appearingAppIsLeftAlone() async {
        let clock = ParkedClock(), window = AppWindow(frontmost: nil)
        WindowFronting(clock: clock).bringToFront(window)
        await settle { clock.parked == 1 }
        window.frontmost = 200
        clock.releaseAll()
        await drain()
        #expect(window.log == ["request", "front"])
    }

    // Red if the capture happens once per window instead of once per call: the second open's follow-up would compare
    // against the first open's app.
    @Test("each open captures its own frontmost app: the second open, made over another app, is forced")
    func eachOpenCapturesItsOwn() async {
        let clock = ParkedClock(), window = AppWindow(frontmost: 100)
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)
        await settle { clock.parked == 1 }
        window.frontmost = 200
        fronting.bringToFront(window)  // the user is now in app 200 and asks again
        await settle { clock.parked == 2 }
        clock.releaseAll()
        await settle { window.log.contains("force") }
        await drain()
        #expect(window.log.filter { $0 == "force" }.count == 1)
    }
}

@Suite("TASK-521 row g: a miniaturized window comes forward") struct Task521MiniaturizedAdapterTests {
    private func orderFrontBody(_ adapter: String) -> String? {
        guard let start = adapter.range(of: "func orderFrontAndMakeKey() {") else { return nil }
        let rest = adapter[start.upperBound...]
        guard let end = rest.range(of: "\n    }") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    // Red if the deminiaturize call is removed, is not conditional on `isMiniaturized`, or moves after the ordering calls.
    @Test("orderFrontAndMakeKey deminiaturizes a miniaturized window before it orders it front and makes it key")
    func deminiaturizesFirst() throws {
        let adapter = try frd008Code("App/Flotsam/WindowFrontAdapter.swift")
        let body = try #require(orderFrontBody(adapter), "found orderFrontAndMakeKey")
        let deminiaturize = try #require(body.range(of: "if window.isMiniaturized { window.deminiaturize(nil) }"))
        let regardless = try #require(body.range(of: "window.orderFrontRegardless()"))
        let key = try #require(body.range(of: "window.makeKeyAndOrderFront(nil)"))
        #expect(deminiaturize.upperBound <= regardless.lowerBound)
        #expect(deminiaturize.upperBound <= key.lowerBound)
    }

    // Red if `windowIsOpen` goes back to `isVisible` alone (false for a miniaturized window: the follow-up would be
    // suppressed for a window the user just asked for).
    @Test("a miniaturized window counts as open, so it does not suppress the follow-up")
    func miniaturizedCountsAsOpen() throws {
        let adapter = try frd008Code("App/Flotsam/WindowFrontAdapter.swift")
        #expect(adapter.contains("var windowIsOpen: Bool { window.isVisible || window.isMiniaturized }"))
    }

    // Red if a controller starts fronting a window itself, bypassing the adapter's deminiaturize.
    @Test("the three window controllers neither miniaturize nor deminiaturize themselves: the adapter is the one home")
    func adapterIsTheOneHome() throws {
        for path in [
            "App/Flotsam/Settings/SettingsWindowController.swift",
            "App/Flotsam/Library/ItemBindingsEditorWindowController.swift",
            "App/Flotsam/OnboardingWindowController.swift",
        ] {
            let code = try frd008Code(path)
            #expect(!code.contains("deminiaturize"), "\(path)")
            #expect(code.contains("WindowFrontAdapter(window: window)"), "\(path)")
        }
    }
}
