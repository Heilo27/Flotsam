import Foundation
import Testing
@testable import FlotsamBase

// Worf TASK-521 adversarial pass over WindowFronting (OC-8024 / FR-008-03 / AC-008-03). Task521WindowFrontingTests pins the
// single-window happy paths; these attack the two rules the builder named (never force at launch, never force a window
// closed during the grace) and the neighbours of each: overlapping opens, a second window in play, and the source scans
// that are supposed to keep a new activation call from slipping in. Each test names the product edit that turns it red.
// What only a real macOS shows (the refusal itself) is the live
// matrix's (TASK-518), not asserted here.

// MARK: - Harness

/// A clock whose sleeps park until the test releases them one by one, and which, like `SystemClock`, returns early
/// (without a throw) when the sleeping task is cancelled.
@MainActor
private final class AdversaryClock: WallClock {
    nonisolated func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }

    final class Sleeper: @unchecked Sendable {
        var cancelled = false
        var done = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private(set) var sleepers: [Sleeper] = []
    private(set) var requested: [Duration] = []

    nonisolated func sleep(for duration: Duration) async {
        let sleeper = Sleeper()
        await withTaskCancellationHandler {
            await park(sleeper, duration)
        } onCancel: {
            Task { @MainActor in self.wake(sleeper, cancelled: true) }
        }
    }

    private func park(_ sleeper: Sleeper, _ duration: Duration) async {
        requested.append(duration)
        sleepers.append(sleeper)
        if sleeper.cancelled { sleeper.done = true; return }
        await withCheckedContinuation { sleeper.continuation = $0 }
    }

    private func wake(_ sleeper: Sleeper, cancelled: Bool) {
        if cancelled { sleeper.cancelled = true }
        guard !sleeper.done, let continuation = sleeper.continuation else { return }
        sleeper.done = true
        sleeper.continuation = nil
        continuation.resume()
    }

    /// Sleeps begun and not yet finished (neither released nor woken by a cancel).
    var pending: Int { sleepers.filter { !$0.done }.count }
    /// Sleeps begun in total.
    var begun: Int { sleepers.count }

    /// The grace period of the `index`th sleep ends.
    func release(_ index: Int) { wake(sleepers[index], cancelled: false) }
    func releaseAll() { for sleeper in sleepers { wake(sleeper, cancelled: false) } }
}

/// Every window records into the log it is given, so two windows share one timeline.
@MainActor
private final class RecordingWindow: FrontableWindow {
    let name: String
    let timeline: Timeline
    var active = false
    var open = true
    var frontmost: Int32? = 100
    var appIsActive: Bool { active }
    var frontmostAppID: Int32? { frontmost }
    var windowIsOpen: Bool { open }
    init(_ name: String, _ timeline: Timeline) { self.name = name; self.timeline = timeline }
    func requestAppActivation() { timeline.events.append("\(name):request") }
    func orderFrontAndMakeKey() { timeline.events.append("\(name):front") }
    func forceAppActivation() { timeline.events.append("\(name):force") }
    func count(_ verb: String) -> Int { timeline.events.filter { $0 == "\(name):\(verb)" }.count }
}

@MainActor
private final class Timeline { var events: [String] = [] }

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<2_000 where !condition() { await Task.yield() }
}

/// Lets every ready follow-up run to its end. Used where the assertion is that nothing more happens.
@MainActor
private func drain() async { for _ in 0..<200 { await Task.yield() } }

// MARK: - Runtime attacks

@MainActor
@Suite("Worf TASK-521 OC-8024 adversarial: WindowFronting rules") struct Worf521WindowFrontingRuleTests {
    // OC-521-W01. Red if `guard forcing else { return }` is removed or inverted (the launch show forces), or if a
    // non-forcing call leaves state behind that stops a later user-asked show from forcing.
    @Test("W01: a launch-style show never forces however long the app stays behind; the user's own show right after still does, once")
    func launchShowNeverForcesThenUserShowDoes() async {
        // given: the app stays behind (active == false), the window stays open
        let clock = AdversaryClock(), timeline = Timeline(), window = RecordingWindow("S", timeline)
        let fronting = WindowFronting(clock: clock)
        // when: two launch-style shows (non-forcing), time passes
        fronting.bringToFront(window, forcing: false)
        fronting.bringToFront(window, forcing: false)
        await drain()
        clock.releaseAll()
        await drain()
        // then: asked twice, shown twice, no sleep begun, no force
        #expect(timeline.events == ["S:request", "S:front", "S:request", "S:front"])
        #expect(clock.begun == 0, "a launch-style show schedules no follow-up at all")
        // when: the user then asks for the same window (Show Setup Guide...)
        fronting.bringToFront(window)
        await settle { clock.pending == 1 }
        clock.releaseAll()
        await settle { window.count("force") == 1 }
        await drain()
        // then: exactly one force, after the user's own grace
        #expect(window.count("force") == 1)
        #expect(timeline.events.suffix(4) == ["S:request", "S:front", "S:force", "S:front"])
    }

    // OC-521-W02. Red if `window.windowIsOpen` is read before the grace instead of after it (a closed window forced), or
    // if the follow-up latches the closed state instead of reading it at the end of the grace.
    @Test("W02: a window closed during the grace is not forced and not ordered front again; closed then reopened inside the grace is")
    func closedDuringGraceBoundaries() async {
        // given: a refused activation and a window that closes inside the grace
        let clock = AdversaryClock(), timeline = Timeline()
        let closed = RecordingWindow("C", timeline)
        WindowFronting(clock: clock).bringToFront(closed)
        await settle { clock.pending == 1 }
        closed.open = false
        clock.release(0)
        await drain()
        // then: nothing after the show: a force or a re-front would raise the closed window again
        #expect(timeline.events == ["C:request", "C:front"])

        // given: a window that closes and reopens inside the grace
        let reopened = RecordingWindow("R", timeline)
        WindowFronting(clock: clock).bringToFront(reopened)
        await settle { clock.pending == 1 }
        reopened.open = false
        reopened.open = true
        clock.release(1)
        await settle { reopened.count("force") == 1 }
        // then: judged on how it stands when the grace ends
        #expect(reopened.count("force") == 1)
        #expect(closed.count("force") == 0)
    }

    // OC-521-W03. Red if `followUp?.cancel()` is removed, or `!Task.isCancelled` is dropped from the guard (a cancelled
    // follow-up wakes at once, as `SystemClock` does, and would force before any grace has run).
    @Test("W03: fifty rapid opens inside one grace period force exactly once, at the last open's deadline")
    func rapidReopensForceOnce() async {
        // given: 50 forcing opens of one window, the app staying behind, no grace released yet
        let clock = AdversaryClock(), timeline = Timeline(), window = RecordingWindow("S", timeline)
        let fronting = WindowFronting(clock: clock)
        for _ in 0..<50 { fronting.bringToFront(window) }
        await settle { clock.begun == 50 }
        await drain()
        // then: the 49 superseded follow-ups woke on cancel and did nothing; the last is still waiting
        #expect(clock.begun == 50)
        #expect(clock.pending == 1, "only the last open's follow-up is alive")
        #expect(window.count("force") == 0, "a superseded follow-up must not force when it wakes")
        #expect(window.count("request") == 50)
        // when: the last grace ends
        clock.releaseAll()  // releases only the live sleeper: the other 49 already woke on cancel
        await settle { window.count("force") == 1 }
        await drain()
        // then: one force, one extra front
        #expect(window.count("force") == 1)
        #expect(window.count("front") == 51)
    }

    // OC-521-W04. Red if the follow-up remembers it already forced (a once-per-window latch), or if the cancelled
    // earlier cycle blocks the next one.
    @Test("W04: a second open after the first was forced starts a fresh cycle and forces again")
    func secondCycleForcesAgain() async {
        // given: a first cycle that ran to its force
        let clock = AdversaryClock(), timeline = Timeline(), window = RecordingWindow("S", timeline)
        let fronting = WindowFronting(clock: clock)
        fronting.bringToFront(window)
        await settle { clock.pending == 1 }
        clock.release(0)
        await settle { window.count("force") == 1 }
        // when: the user opens it again and the system refuses again
        fronting.bringToFront(window)
        await settle { clock.pending == 1 }
        clock.release(1)
        await settle { window.count("force") == 2 }
        // then: the whole sequence, twice
        #expect(timeline.events == [
            "S:request", "S:front", "S:force", "S:front",
            "S:request", "S:front", "S:force", "S:front",
        ])
        #expect(clock.begun == 2)
    }

    // OC-521-W05. Red if the follow-up is shared between windows (a static or singleton `followUp`): the second window's
    // open would cancel the first's. Windows are Settings and the item editor, each with its own WindowFronting.
    @Test("W05: a second window opened inside the first one's grace does not cancel the first one's follow-up; each is forced once, by its own call")
    func twoWindowsKeepTheirOwnFollowUps() async {
        // given: Settings opens, then the editor opens 100 ms later, app still behind
        let clock = AdversaryClock(), timeline = Timeline()
        let settings = RecordingWindow("Settings", timeline), editor = RecordingWindow("Editor", timeline)
        WindowFronting(clock: clock).bringToFront(settings)
        await settle { clock.pending == 1 }
        WindowFronting(clock: clock).bringToFront(editor)
        await settle { clock.pending == 2 }
        // when: Settings' grace ends, then the editor's
        clock.release(0)
        await settle { settings.count("force") == 1 }
        clock.release(1)
        await settle { editor.count("force") == 1 }
        await drain()
        // then: one force each, and the editor, opened last, is the last window ordered front
        #expect(settings.count("force") == 1)
        #expect(editor.count("force") == 1)
        #expect(timeline.events.last == "Editor:front")
        #expect(timeline.events.filter { $0.hasSuffix(":force") } == ["Settings:force", "Editor:force"])
    }

    // OC-521-W06. Red if the follow-up orders the window front without first checking the app is still behind, or drops the
    // `!window.appIsActive` check. `appIsActive` is app-wide: another Flotsam window (the editor) took key and the app is
    // frontmost, so the first window must not be pulled back over it.
    @Test("W06: when another Flotsam window took key and the app is frontmost, the earlier window is neither forced nor re-ordered front")
    func otherWindowKeyLeavesEarlierWindowAlone() async {
        // given: Settings opened, then the editor; the system accepted the activation (app frontmost)
        let clock = AdversaryClock(), timeline = Timeline()
        let settings = RecordingWindow("Settings", timeline), editor = RecordingWindow("Editor", timeline)
        WindowFronting(clock: clock).bringToFront(settings)
        await settle { clock.pending == 1 }
        WindowFronting(clock: clock).bringToFront(editor)
        await settle { clock.pending == 2 }
        settings.active = true
        editor.active = true
        // when: both graces end
        clock.releaseAll()
        await drain()
        // then: nothing beyond the two opens
        #expect(timeline.events == ["Settings:request", "Settings:front", "Editor:request", "Editor:front"])
    }

    // OC-521-W07. Red if the guard `!window.windowIsOpen` is dropped: the replaced editor window (closed when the editor
    // opens another item) would force the app and raise itself, while the new window is the one the user wants.
    @Test("W07: an editor window replaced inside its grace is not forced; the replacement is, once")
    func replacedWindowDoesNotForce() async {
        // given: the editor for item A opens, then is closed and replaced by item B's window inside the grace
        let clock = AdversaryClock(), timeline = Timeline()
        let itemA = RecordingWindow("ItemA", timeline), itemB = RecordingWindow("ItemB", timeline)
        WindowFronting(clock: clock).bringToFront(itemA)
        await settle { clock.pending == 1 }
        itemA.open = false
        WindowFronting(clock: clock).bringToFront(itemB)
        await settle { clock.pending == 2 }
        // when: both graces end
        clock.releaseAll()
        await settle { itemB.count("force") == 1 }
        await drain()
        // then: only the replacement forced
        #expect(itemA.count("force") == 0)
        #expect(itemA.count("front") == 1, "the closed window is not ordered front again")
        #expect(itemB.count("force") == 1)
    }
}

// MARK: - The activation scan

/// What window-activation or window-ordering calls a Swift source contains, by name. Comments (whole-line and block) are
/// ignored; a trailing comment is NOT stripped, so it fails closed (a false alarm to fix, never a hidden call).
private func activationSymbols(in source: String) -> Set<String> {
    var text = source.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
    text = text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    let rules: [(String, String)] = [
        ("activate", #"(?<!NSLayoutConstraint)\.\s*activate\s*\("#),
        ("activateIgnoringOtherApps", #"activateIgnoringOtherApps"#),
        ("openApplication", #"\.\s*openApplication\s*\("#),
        ("ownBundleURL", #"Bundle\.main\s*\.\s*(bundleURL|bundlePath)"#),
        ("orderFrontRegardless", #"orderFrontRegardless"#),
        ("makeKeyAndOrderFront", #"makeKeyAndOrderFront"#),
        ("makeKey", #"\.\s*makeKey\s*\("#),
        ("orderFront", #"\.\s*orderFront\s*\("#),
        ("setActivationPolicy", #"setActivationPolicy"#),
        ("unhide", #"\.\s*unhide\s*\("#),
        ("selectorActivate", #"(Selector\s*\(|#selector\s*\()[^)]*activate"#),
    ]
    var found: Set<String> = []
    for (name, pattern) in rules where text.range(of: pattern, options: .regularExpression) != nil { found.insert(name) }
    return found
}

/// Every Swift file under `relativeRoot` mapped to the symbols it uses, files with none left out.
private func activationMap(under relativeRoot: String) throws -> [String: Set<String>] {
    let root = try frd008SourceRoot()
    let base = root.appendingPathComponent(relativeRoot)
    var result: [String: Set<String>] = [:]
    let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        let text = try String(contentsOf: url, encoding: .utf8)
        let symbols = activationSymbols(in: text)
        if !symbols.isEmpty { result[url.path.replacingOccurrences(of: root.path + "/", with: "")] = symbols }
    }
    return result
}

private func sourceFileCount(under relativeRoot: String) throws -> Int {
    let base = try frd008SourceRoot().appendingPathComponent(relativeRoot)
    var count = 0
    let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
        if url.pathExtension == "swift" { count += 1 }
    }
    return count
}

private func count(of pattern: String, in text: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return -1 }
    return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
}

/// Occurrences of `pattern` in every Swift file under `relativeRoot`, as "relative path: count", whole-line comments ignored.
private func occurrences(of pattern: String, under relativeRoot: String) throws -> [String: Int] {
    let root = try frd008SourceRoot()
    let base = root.appendingPathComponent(relativeRoot)
    var result: [String: Int] = [:]
    let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        let text = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        let n = count(of: pattern, in: text)
        if n > 0 { result[url.path.replacingOccurrences(of: root.path + "/", with: "")] = n }
    }
    return result
}

@Suite("Worf TASK-521 OC-8024 adversarial: no activation call slips past the scan") struct Worf521ActivationScanTests {
    // OC-521-S01. The scanner itself. Red if any pattern is loosened: every row is a way to activate Flotsam or order a window
    // front that the shipped scan (`NSApp.activate(` / `NSApplication.shared.activate(` / `makeKeyAndOrderFront` only, over
    // App/Flotsam only, with five files exempt wholesale) does not see.
    @Test("S01: the scanner sees every spelling of activating the app or ordering a window front, and none of the harmless ones")
    func scannerCatchesTheSlips() {
        let slips: [(String, String)] = [
            ("NSRunningApplication.current.activate(options: [])", "activate"),
            ("let app = NSApplication.shared\n    app.activate(ignoringOtherApps: true)", "activate"),
            ("NSApp . activate ()", "activate"),
            ("NSApp\n    .activate()", "activate"),
            ("NSApp.activate(ignoringOtherApps: true)", "activate"),
            ("app.activateIgnoringOtherApps", "activateIgnoringOtherApps"),
            ("NSWorkspace.shared.openApplication(at: u, configuration: c) { _, _ in }", "openApplication"),
            ("NSWorkspace.shared.open(Bundle.main.bundleURL)", "ownBundleURL"),
            ("window.orderFrontRegardless()", "orderFrontRegardless"),
            ("window.makeKeyAndOrderFront(nil)", "makeKeyAndOrderFront"),
            ("window.makeKey()", "makeKey"),
            ("window.orderFront(nil)", "orderFront"),
            ("NSApp.setActivationPolicy(.regular)", "setActivationPolicy"),
            ("NSApp.unhide(nil)", "unhide"),
            ("NSApp.perform(Selector(\"activate\"))", "selectorActivate"),
            ("let x = 1 // NSApp.activate() trailing comment is flagged: fail closed\nNSApp.activate()", "activate"),
        ]
        for (code, symbol) in slips {
            #expect(activationSymbols(in: code).contains(symbol), "\(symbol) must be seen in: \(code); saw \(activationSymbols(in: code))")
        }
        let harmless = [
            "NSLayoutConstraint.activate([a, b])",
            "// NSApp.activate()",
            "    /// Calls `NSApp.activate()` first.",
            "/* NSApp.activate()\n   window.orderFrontRegardless() */",
            "let deactivate = reactivate(item); item.isActivated = true",
            "NSWorkspace.shared.open(url)",
        ]
        for code in harmless { #expect(activationSymbols(in: code).isEmpty, "must not be flagged: \(code)") }
    }

    // OC-521-S02. Red if ANY App or package file gains an activation or ordering call, or if one of the five files the
    // shipped scan exempts wholesale (LibraryPanelController, ShelfPanelController, ErrorPresenterAdapter, FatalAlert,
    // WindowFrontAdapter) gains a different one, or if App/Platform (not walked by the shipped scan) gains one.
    @Test("S02: the set of files and calls that activate the app or order a window front is exactly the known one, across all of App/ and the packages")
    func exactActivationInventory() throws {
        #expect(try sourceFileCount(under: "App") > 40, "the walk reached the App sources")
        #expect(try sourceFileCount(under: "App/Platform") >= 3, "the walk reached App/Platform, which the shipped scan skips")
        #expect(try sourceFileCount(under: "Packages/FlotsamCore/Sources") > 100)
        let app = try activationMap(under: "App")
        #expect(app == [
            "App/Flotsam/WindowFrontAdapter.swift": ["activate", "openApplication", "ownBundleURL", "orderFrontRegardless", "makeKeyAndOrderFront"],
            "App/Flotsam/FatalAlert.swift": ["activate"],
            "App/Flotsam/ErrorPresenterAdapter.swift": ["orderFrontRegardless"],
            "App/Flotsam/Library/LibraryPanelController.swift": ["makeKeyAndOrderFront"],
            "App/Flotsam/Shelf/ShelfPanelController.swift": ["makeKeyAndOrderFront", "orderFrontRegardless"],
            "App/Flotsam/FlotsamApp.swift": ["setActivationPolicy"],  // .accessory at launch: no Dock icon
        ])
        let packages = try activationMap(under: "Packages/FlotsamCore/Sources")
        #expect(packages == [:], "the packages never touch window activation: \(packages)")
    }

    // OC-521-S03. Red if a second caller of the forced activation appears anywhere: it would be a path that forces without
    // going through the grace and the closed-window, user-asked and still-the-same-frontmost-app checks.
    @Test("S03: forceAppActivation has one call site, the WindowFronting follow-up, behind its four checks, and the adapter is its only implementation")
    func forceHasOneCaller() throws {
        let calls = try occurrences(of: #"\.forceAppActivation\s*\("#, under: "Packages/FlotsamCore/Sources")
            .merging(try occurrences(of: #"\.forceAppActivation\s*\("#, under: "App")) { a, b in a + b }
        #expect(calls == ["Packages/FlotsamCore/Sources/FlotsamBase/Ports/WindowFronting.swift": 1])
        let impls = try occurrences(of: #"func forceAppActivation\s*\("#, under: "App")
        #expect(impls == ["App/Flotsam/WindowFrontAdapter.swift": 1])
        // and the follow-up's call sits behind all four checks, in that file
        let fronting = try frd008Code("Packages/FlotsamCore/Sources/FlotsamBase/Ports/WindowFronting.swift")
        #expect(fronting.contains("guard !Task.isCancelled, window.windowIsOpen, !window.appIsActive,"))
        #expect(fronting.contains("window.frontmostAppID == frontmostAtCall else { return }"))
        #expect(fronting.contains("guard forcing else { return }"))
    }

    // OC-521-S04. Red if a new window entry point is added (or an existing one gains a call) without this list changing: the
    // reviewer must then decide whether the new call is an explicit user open (forcing) or not (`forcing: false`).
    @Test("S04: bringToFront has exactly the known call sites, and the setup guide's launch show is the only one that can pass forcing: false")
    func bringToFrontCallSites() throws {
        let calls = try occurrences(of: #"(?<![A-Za-z])bringToFront\s*\("#, under: "App")
        #expect(calls == [
            "App/Flotsam/Settings/SettingsWindowController.swift": 2,  // the handle method and its one forwarding call
            "App/Flotsam/OnboardingWindowController.swift": 2,
            "App/Flotsam/Library/ItemBindingsEditorWindowController.swift": 2,
            "App/Flotsam/WindowFrontAdapter.swift": 2,  // the adapter method and the WindowFronting call
        ])
        // `forcing:` appears only where the launch rule lives: the adapter's pass-through and the setup guide
        let forcing = try occurrences(of: #"forcing\s*:"#, under: "App")
        #expect(forcing == ["App/Flotsam/WindowFrontAdapter.swift": 2, "App/Flotsam/OnboardingWindowController.swift": 2])
        #expect(try occurrences(of: #"forcing\s*:\s*(true|false)"#, under: "App") == [:], "no call hard-codes the choice")
    }

    // OC-521-S05. Red if the launch-time call stops passing `resuming: true` (then the setup guide forces at login), or if a
    // third unconditional `show()` is added to the launch path.
    @Test("S05: the launch path shows the setup guide only through show(resuming: true); every other show is a user's closure")
    func launchShowIsResuming() throws {
        let delegate = try frd008Code("App/Flotsam/AppDelegate.swift")
        let shows = count(of: #"onboarding\.show\("#, in: delegate)
        let resuming = count(of: #"onboarding\.show\(resuming:\s*true\)"#, in: delegate)
        // TASK-524: the two user entry points (Settings button, menu-bar row) share ONE closure, which hides the Library
        // and then shows the guide. One definition, handed to both consumers.
        let userClosures = count(of: #"let showSetupGuide[^=]*=\s*\{[^}]*onboarding\.show\(\)\s*\}"#, in: delegate)
        let consumers = count(of: #"showSetupGuide:\s*showSetupGuide\)"#, in: delegate)
        #expect(shows == 2)
        #expect(resuming == 1)
        #expect(userClosures == 1, "the one user closure: hide the Library, then show")
        #expect(consumers == 2, "the Settings button and the menu-bar row both take it")
        #expect(delegate.contains("if OnboardingFlow.shouldShowAutomatically(settings: container.settings) { onboarding.show(resuming: true) }"))
        // nothing else can reach OnboardingWindowController.show
        #expect(try occurrences(of: #"OnboardingWindowController\("#, under: "App") == ["App/Flotsam/AppDelegate.swift": 1])
        let controller = try frd008Code("App/Flotsam/OnboardingWindowController.swift")
        #expect(controller.contains("front.bringToFront(forcing: !resuming)"))
    }
}
