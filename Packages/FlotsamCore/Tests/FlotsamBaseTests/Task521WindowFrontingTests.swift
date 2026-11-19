import Foundation
import Testing
@testable import FlotsamBase

// TASK-521 / OC-8024 / FR-008-03. ⌘, from the Library (a non-activating panel over another app) opened Settings behind
// that app and the next key went to it: the plain `NSApp.activate()` request was refused. `WindowFronting` is the one
// home of the sequence (ask, show, check, force); these tests pin the sequence with a fake window, and a source scan
// pins that every App entry point goes through it. What only a real macOS shows (the refusal itself) is the live matrix's.

/// A clock whose `sleep` parks until the test releases it.
@MainActor
private final class ParkedClock: WallClock {
    nonisolated func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private(set) var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func sleep(for duration: Duration) async { await park(duration) }

    private func park(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { waiters.append($0) }
    }

    var parked: Int { waiters.count }

    func releaseAll() {
        let all = waiters
        waiters = []
        for waiter in all { waiter.resume() }
    }
}

@MainActor
private final class FakeFrontable: FrontableWindow {
    var log: [String] = []
    /// What `appIsActive` answers; a test flips it to model the system accepting or refusing the request.
    var active = false
    var appIsActive: Bool { active }
    func requestAppActivation() { log.append("request") }
    func orderFrontAndMakeKey() { log.append("front") }
    func forceAppActivation() { log.append("force") }
    func endForcedActivation() { log.append("end") }
}

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<2_000 where !condition() { await Task.yield() }
}

@MainActor
@Suite("TASK-521 OC-8024: windows are brought in front of the app the user was in") struct Task521WindowFrontingTests {
    @Test("activation is requested before the window is shown")
    func requestThenFront() async {
        let clock = ParkedClock(), window = FakeFrontable()
        WindowFronting(clock: clock).bringToFront(window)
        #expect(window.log == ["request", "front"])
    }

    @Test("an activation the system accepted is left alone: no force, no policy change")
    func acceptedActivation() async {
        let clock = ParkedClock(), window = FakeFrontable()
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)
        await settle { clock.parked == 1 }
        window.active = true
        clock.releaseAll()
        await settle { clock.parked > 0 }  // nothing further parks: the follow-up returned
        for _ in 0..<50 { await Task.yield() }
        #expect(window.log == ["request", "front"])
        #expect(clock.requested == [WindowFronting.activationGrace])
    }

    @Test("a refused activation is forced, the window is ordered front again, and the policy is restored after the hold")
    func refusedActivationIsForced() async {
        let clock = ParkedClock(), window = FakeFrontable()
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)
        await settle { clock.parked == 1 }
        #expect(window.log == ["request", "front"], "nothing is forced before the grace period ends")
        clock.releaseAll()
        await settle { clock.parked == 1 }
        #expect(window.log == ["request", "front", "force", "front"])
        #expect(clock.requested == [WindowFronting.activationGrace, WindowFronting.forcedHold])
        clock.releaseAll()
        await settle { window.log.last == "end" }
        #expect(window.log == ["request", "front", "force", "front", "end"])
    }

    @Test("opening again while the first follow-up waits cancels it: one force, not two")
    func reopenCancelsEarlierFollowUp() async {
        let clock = ParkedClock(), window = FakeFrontable()
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)
        await settle { clock.parked == 1 }
        fronting.bringToFront(window)
        await settle { clock.parked == 2 }
        clock.releaseAll()
        await settle { clock.parked == 1 }
        #expect(window.log.filter { $0 == "force" }.count == 1)
        clock.releaseAll()
        await settle { window.log.last == "end" }
        #expect(window.log.filter { $0 == "request" }.count == 2)
        #expect(window.log.filter { $0 == "end" }.count == 1)
    }

    @Test("a forced policy is always restored, even when a newer open cancels the follow-up during the hold")
    func policyRestoredWhenCancelledDuringHold() async {
        let clock = ParkedClock(), window = FakeFrontable()
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)
        await settle { clock.parked == 1 }
        clock.releaseAll()
        await settle { clock.parked == 1 }
        #expect(window.log.contains("force"))
        window.active = true
        fronting.bringToFront(window)
        clock.releaseAll()
        await settle { window.log.contains("end") }
        #expect(window.log.filter { $0 == "end" }.count == 1)
    }

    // The sequence has one home. Every App window that must come in front goes through it; none calls AppKit directly.
    @Test("every App entry point (Settings, the item editor, the setup guide) fronts through WindowFrontAdapter, and only it activates")
    func entryPointsShareTheOneSequence() throws {
        for path in [
            "App/Flotsam/Settings/SettingsWindowController.swift",
            "App/Flotsam/Library/ItemBindingsEditorWindowController.swift",
            "App/Flotsam/OnboardingWindowController.swift",
        ] {
            let code = try frd008Code(path)
            #expect(code.contains("WindowFrontAdapter(window: window)"), "\(path) builds the adapter")
            #expect(code.contains("front.bringToFront()") || code.contains("front?.bringToFront()"), "\(path) fronts through it")
            #expect(!code.contains("makeKeyAndOrderFront"), "\(path) must not order a window front itself")
            #expect(!code.contains(".activate("), "\(path) must not activate the app itself")
        }
        let adapter = try frd008Code("App/Flotsam/WindowFrontAdapter.swift")
        #expect(adapter.contains("WindowFronting(clock: SystemClock())"))
        #expect(adapter.contains("func requestAppActivation() { NSApp.activate() }"))
        #expect(adapter.contains("window.orderFrontRegardless()"))
        #expect(adapter.contains("window.makeKeyAndOrderFront(nil)"))
        #expect(adapter.contains("NSApp.setActivationPolicy(.regular)"))
        #expect(adapter.contains("func endForcedActivation() { NSApp.setActivationPolicy(.accessory) }"))
    }

    // ⌘, in the Library, the menu-bar row and any "Open Settings" action all end at `actions.openSettings`, which is the
    // Settings driver's `open()`, which fronts the window on every call (Frd008SettingsWindowDriverTests).
    @Test("⌘, in the Library and the menu-bar row take the same openSettings closure")
    func settingsEntryPointsShareOneClosure() throws {
        let container = try frd008Code("App/Flotsam/AppContainer.swift")
        #expect(container.contains("openSettings: { [weak self] in self?.actions.openSettings?() }"))
        #expect(container.contains("actions.openSettings = { [weak window] in window?.openSettings() }"))
        let status = try frd008Code("App/Flotsam/StatusItemController.swift")
        #expect(status.contains("run: container.actions.openSettings"))
    }

    // Only the two non-activating panels may order themselves front without the shared sequence.
    @Test("no other App file orders a window front or activates the app")
    func noOtherActivation() throws {
        let root = try frd008SourceRoot().appendingPathComponent("App/Flotsam")
        let allowed: Set<String> = [
            "WindowFrontAdapter.swift", "LibraryPanelController.swift", "ShelfPanelController.swift",
            "ErrorPresenterAdapter.swift", "FatalAlert.swift",
        ]
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL, url.pathExtension == "swift" {
            guard !allowed.contains(url.lastPathComponent) else { continue }
            let code = try frd008Code("App/Flotsam/" + url.path.replacingOccurrences(of: root.path + "/", with: ""))
            if code.contains("makeKeyAndOrderFront") || code.contains("NSApp.activate(") || code.contains("NSApplication.shared.activate(") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders == [], "window fronting has one home, WindowFrontAdapter")
    }
}
