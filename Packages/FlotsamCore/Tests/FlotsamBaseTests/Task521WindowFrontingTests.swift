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
    /// What `frontmostAppID` answers; a test changes it to model the user switching apps.
    var frontmost: Int32? = 100
    var frontmostAppID: Int32? { frontmost }
    /// What `windowIsOpen` answers; a test flips it to model the window closing during the grace period.
    var open = true
    var windowIsOpen: Bool { open }
    func requestAppActivation() { log.append("request") }
    func orderFrontAndMakeKey() { log.append("front") }
    func forceAppActivation() { log.append("force") }
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

    @Test("an activation the system accepted is left alone: no force")
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

    @Test("a refused activation is forced once the grace period ends, then the window is ordered front again")
    func refusedActivationIsForced() async {
        let clock = ParkedClock(), window = FakeFrontable()
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)
        await settle { clock.parked == 1 }
        #expect(window.log == ["request", "front"], "nothing is forced before the grace period ends")
        clock.releaseAll()
        await settle { window.log.count == 4 }
        #expect(window.log == ["request", "front", "force", "front"])
        #expect(clock.requested == [WindowFronting.activationGrace])
    }

    @Test("a window closed during the grace period is not forced")
    func closedWindowIsNotForced() async {
        let clock = ParkedClock(), window = FakeFrontable()
        WindowFronting(clock: clock).bringToFront(window)
        await settle { clock.parked == 1 }
        window.open = false
        clock.releaseAll()
        for _ in 0..<50 { await Task.yield() }
        #expect(window.log == ["request", "front"])
    }

    @Test("a show the user did not ask for (forcing: false) asks and shows but never schedules or forces")
    func unrequestedShowIsNeverForced() async {
        let clock = ParkedClock(), window = FakeFrontable()
        WindowFronting(clock: clock).bringToFront(window, forcing: false)
        for _ in 0..<50 { await Task.yield() }
        #expect(window.log == ["request", "front"])
        #expect(clock.requested.isEmpty, "no follow-up is scheduled")
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
        await settle { window.log.contains("force") }
        for _ in 0..<50 { await Task.yield() }
        #expect(window.log.filter { $0 == "force" }.count == 1)
        #expect(window.log.filter { $0 == "request" }.count == 2)
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
            #expect(
                code.contains("front.bringToFront(") || code.contains("front?.bringToFront("), "\(path) fronts through it")
            #expect(!code.contains("makeKeyAndOrderFront"), "\(path) must not order a window front itself")
            #expect(!code.contains(".activate("), "\(path) must not activate the app itself")
        }
        // The launch-time setup guide is Flotsam's own show, so it must not force activation (a login-item start).
        let onboarding = try frd008Code("App/Flotsam/OnboardingWindowController.swift")
        #expect(onboarding.contains("front.bringToFront(forcing: !resuming)"))
        let adapter = try frd008Code("App/Flotsam/WindowFrontAdapter.swift")
        #expect(adapter.contains("WindowFronting(clock: SystemClock())"))
        #expect(adapter.contains("func requestAppActivation() { NSApp.activate() }"))
        #expect(adapter.contains("window.orderFrontRegardless()"))
        #expect(adapter.contains("window.makeKeyAndOrderFront(nil)"))
        // The forced step is LaunchServices opening the app's own bundle with `activates`; it never touches the policy,
        // so no Dock icon appears. (In-process activation variants were refused on macOS 26.)
        #expect(adapter.contains("NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL"))
        #expect(adapter.contains("configuration.activates = true"))
        #expect(!adapter.contains("setActivationPolicy"))
        #expect(adapter.contains("NSWorkspace.shared.frontmostApplication?.processIdentifier"))
    }

    // ⌘, in the Library, the menu-bar row and any "Open Settings" action all end at `actions.openSettings`, which is the
    // Settings driver's `open()`, which fronts the window on every call (Frd008SettingsWindowDriverTests).
    @Test("⌘, in the Library and the menu-bar row take the same openSettings closure")
    func settingsEntryPointsShareOneClosure() throws {
        let container = try frd008Code("App/Flotsam/AppContainer.swift")
        #expect(container.contains("openSettings: { [weak self] in self?.actions.openSettings?() }"))
        // TASK-524: the closure hides the Library first, then opens the window, and is the whole closure (no other
        // statement); Task524AppWiringTests pins the order from the other side.
        let flat = container.replacingOccurrences(of: ";", with: " ").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        #expect(flat.contains(
            "actions.openSettings = { [weak self, weak window] in self?.hideLibraryBeforeWindowOpens() window?.openSettings() }"))
        let status = try frd008Code("App/Flotsam/StatusItemController.swift")
        #expect(status.contains("run: container.actions.openSettings"))
    }

    // Only the two non-activating panels (and the HUD panel) may order themselves front without the shared sequence. The
    // two modal alerts, FatalAlert and ClearRecentConfirmation (TASK-541), are not windows Flotsam keeps: each activates
    // for the length of its own `runModal` and returns. The FRD does not say how such an alert comes forward when the
    // system refuses a plain activation; that is reported as an open question, not decided here.
    @Test("no other App file orders a window front or activates the app")
    func noOtherActivation() throws {
        let root = try frd008SourceRoot().appendingPathComponent("App/Flotsam")
        let allowed: Set<String> = [
            "WindowFrontAdapter.swift", "LibraryPanelController.swift", "ShelfPanelController.swift",
            "ErrorPresenterAdapter.swift", "FatalAlert.swift", "ClearRecentConfirmation.swift",
        ]
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var scanned = 0
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", !allowed.contains(url.lastPathComponent) else { continue }
            scanned += 1
            let code = try frd008Code("App/Flotsam/" + url.path.replacingOccurrences(of: root.path + "/", with: ""))
            if code.contains("makeKeyAndOrderFront") || code.contains("NSApp.activate(") || code.contains("NSApplication.shared.activate(") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(scanned > 20, "the scan walked the App sources (a non-Swift file must not end it)")
        #expect(offenders == [], "window fronting has one home, WindowFrontAdapter")
    }
}
