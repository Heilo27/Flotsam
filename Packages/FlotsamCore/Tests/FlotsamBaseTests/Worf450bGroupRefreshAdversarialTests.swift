import Foundation
import Testing
@testable import FlotsamBase

// TASK-450 re-QA (Worf). The re-work moved the permission rows' `rows` state up into TriggersPane and replaced the
// per-view loops with one `refreshWhileVisible` per pane group. Two seams are checked here:
//  - behaviour: the exact composition TriggersPane uses (`PermissionRow.current(probe:)` driven by one `VisibleRefresh`)
//    updates the rows within one interval of a change, stops while hidden, and reads each permission once per tick;
//    a dropped owner cancels its pending sleep (cancellation-aware clock, so the deinit cancel is observable on its own,
//    not hidden behind the weak owner).
//  - structure: the App target cannot be hosted by a package test, so the wiring (one loop for the group, none per row,
//    the only 2 s cadence is `VisibleRefresh.interval`, the modifier delegates the visibility rule) is a source scan,
//    the same recorded pattern as Worf460OnboardingLoginReadGuardTests. Expected values are literals only.

/// Parks every sleep until released; ignores cancellation (so extra reads would show up after release).
@MainActor
private final class W450bParkedClock: WallClock {
    nonisolated func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private(set) var requested = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func sleep(for duration: Duration) async { await park() }

    private func park() async {
        requested += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    var parked: Int { waiters.count }

    func releaseAll() {
        let all = waiters
        waiters = []
        for waiter in all { waiter.resume() }
    }
}

/// Sleeps for a long time but returns the moment its task is cancelled (the production port's contract), and counts the
/// sleeps still pending: a loop that is not cancelled leaves `active` at 1.
@MainActor
private final class W450bCancelAwareClock: WallClock {
    nonisolated func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private(set) var active = 0

    nonisolated func sleep(for duration: Duration) async { await run() }

    private func run() async {
        active += 1
        try? await Task.sleep(for: .seconds(600))
        active -= 1
    }
}

private final class W450bProbe: PermissionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [PermissionKind: Bool] = [:]
    private var reads = 0

    func set(_ kind: PermissionKind, _ granted: Bool) { lock.withLock { grants[kind] = granted } }
    var readCount: Int { lock.withLock { reads } }

    func isGranted(_ kind: PermissionKind) -> Bool { lock.withLock { reads += 1; return grants[kind] ?? false } }
    func request(_ kind: PermissionKind) {}
    func openSystemSettings(_ kind: PermissionKind) {}
}

/// Stands in for TriggersPane's `@State rows`.
@MainActor
private final class W450bRowsBox {
    var rows: [PermissionRow]
    init(_ rows: [PermissionRow]) { self.rows = rows }
}

@MainActor
private func w450bSettle(_ condition: () -> Bool) async {
    for _ in 0..<5_000 where !condition() { await Task.yield() }
}

@MainActor
@Suite struct Worf450bGroupRefreshBehaviourTests {
    /// TriggersPane's wiring: rows seeded in init, one VisibleRefresh whose refresh re-reads every permission.
    private static func wire(probe: W450bProbe, clock: any WallClock) -> (W450bRowsBox, VisibleRefresh) {
        let box = W450bRowsBox(PermissionRow.current(probe: probe))
        let refresher = VisibleRefresh(clock: clock) { box.rows = PermissionRow.current(probe: probe) }
        return (box, refresher)
    }

    // OC-450b-01. Given the Triggers rows both "Not granted" and the pane visible. When Accessibility is granted in
    // System Settings and one interval passes. Then the Accessibility row reads granted, Input Monitoring is unchanged,
    // and there are still two rows (identity, not position). Red if: the refresh does not re-read the probe, or it
    // writes the rows from a stale snapshot.
    @Test func aGrantWhileVisibleShowsOnTheNextTickAndOnlyOnItsRow() async {
        let probe = W450bProbe(), clock = W450bParkedClock()
        let (box, refresher) = Self.wire(probe: probe, clock: clock)
        refresher.setVisible(true)
        await w450bSettle { clock.parked == 1 }
        #expect(box.rows.map(\.isGranted) == [false, false])

        probe.set(.accessibility, true)
        clock.releaseAll()
        await w450bSettle { clock.requested == 2 }

        #expect(box.rows.count == 2)
        #expect(box.rows.first { $0.kind == .accessibility }?.isGranted == true)
        #expect(box.rows.first { $0.kind == .inputMonitoring }?.isGranted == false)
        refresher.setVisible(false)
    }

    // OC-450b-02. Given a granted permission that is then revoked while the pane stays visible. When one interval
    // passes. Then the row flips back to "Not granted" (the opposite direction, and a stale `true` would survive a
    // one-way "only ever sets granted" refresh). Red if: the refresh merges instead of replacing.
    @Test func aRevokeWhileVisibleShowsOnTheNextTick() async {
        let probe = W450bProbe(), clock = W450bParkedClock()
        probe.set(.accessibility, true)
        probe.set(.inputMonitoring, true)
        let (box, refresher) = Self.wire(probe: probe, clock: clock)
        refresher.setVisible(true)
        await w450bSettle { clock.parked == 1 }
        #expect(box.rows.map(\.isGranted) == [true, true])

        probe.set(.inputMonitoring, false)
        clock.releaseAll()
        await w450bSettle { clock.requested == 2 }

        #expect(box.rows.map(\.isGranted) == [true, false])
        refresher.setVisible(false)
    }

    // OC-450b-03. Given the visible pane. When three intervals pass. Then every permission is read once per refresh:
    // 2 kinds x (1 immediate + 3 ticks) = 8 probe reads. One loop for the group, not one per row (a per-row loop would
    // read 2 x that). Red if: PermissionRow.current reads a kind twice, or a second loop is started per row.
    @Test func oneLoopForTheGroupReadsEachPermissionOncePerTick() async {
        let probe = W450bProbe(), clock = W450bParkedClock()
        let (_, refresher) = Self.wire(probe: probe, clock: clock)
        let afterSeed = probe.readCount
        #expect(afterSeed == 2)

        refresher.setVisible(true)
        await w450bSettle { clock.parked == 1 }
        for tick in 2...4 {
            clock.releaseAll()
            await w450bSettle { clock.requested == tick }
        }

        #expect(probe.readCount - afterSeed == 8)
        #expect(clock.parked == 1, "exactly one pending sleep, so exactly one loop")
        refresher.setVisible(false)
    }

    // OC-450b-04. Given the pane hidden (tab switched, window closed). When a permission changes and the old sleep
    // ends. Then the rows stay as they were and the probe is not read again. Red if: hide does not stop the loop.
    @Test func aChangeWhileHiddenIsNotReadUntilVisibleAgain() async {
        let probe = W450bProbe(), clock = W450bParkedClock()
        let (box, refresher) = Self.wire(probe: probe, clock: clock)
        refresher.setVisible(true)
        await w450bSettle { clock.parked == 1 }
        refresher.setVisible(false)
        let readsAtHide = probe.readCount

        probe.set(.accessibility, true)
        clock.releaseAll()
        for _ in 0..<300 { await Task.yield() }
        #expect(probe.readCount == readsAtHide)
        #expect(box.rows.map(\.isGranted) == [false, false])

        refresher.setVisible(true)
        await w450bSettle { clock.requested == 2 }
        #expect(box.rows.map(\.isGranted) == [true, false], "visible again re-reads at once")
        refresher.setVisible(false)
    }

    // OC-450b-05. Given a visible owner with a pending 2 s sleep, on a clock that honours cancellation. When the owner
    // is dropped without a hide signal. Then the pending sleep ends at once (active 0) without the clock being released.
    // Red if: the deinit cancel is removed (the weak owner alone only ends the loop after the sleep, so this is the
    // test that sees the deinit).
    @Test func droppingTheOwnerCancelsThePendingSleepAtOnce() async {
        let clock = W450bCancelAwareClock()
        var refresher: VisibleRefresh? = VisibleRefresh(clock: clock) {}
        refresher?.setVisible(true)
        await w450bSettle { clock.active == 1 }
        #expect(clock.active == 1)

        refresher = nil
        await w450bSettle { clock.active == 0 }

        #expect(clock.active == 0, "a dropped owner must cancel its sleep, not wait out the interval")
    }

    // OC-450b-06. Given a visible owner with a pending sleep. When it is dropped. Then the owner is freed (weak
    // reference nil) even though its loop is parked in a sleep. Red if: the loop holds the owner strongly across the
    // sleep (retain cycle: the owner can never deinit, so deinit-cancel never runs).
    @Test func theLoopDoesNotKeepItsOwnerAlive() async {
        let clock = W450bParkedClock()
        var refresher: VisibleRefresh? = VisibleRefresh(clock: clock) {}
        weak var weakRefresher = refresher
        refresher?.setVisible(true)
        await w450bSettle { clock.parked == 1 }

        refresher = nil

        #expect(weakRefresher == nil, "the parked loop must not retain its owner")
        clock.releaseAll()
    }
}

/// Structure of the App wiring (source scan; the app target has no test host).
@Suite struct Worf450bWiringSourceTests {
    private static var root: URL {
        // .../Packages/FlotsamCore/Tests/FlotsamBaseTests/<this file> -> repo root is five levels up
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    /// Source text with `//` comment lines removed (a doc comment may say "every 2 s"; only code counts).
    private static func code(_ relative: String) throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func swiftFiles(under relative: String) -> [String] {
        let base = root.appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { ($0 as? URL)?.path }
            .filter { $0.hasSuffix(".swift") }
            .map { String($0.dropFirst(root.path.count + 1)) }
            .sorted()
    }

    private static func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // OC-450b-07. Red if: a second 2 s cadence is written anywhere in non-test sources (a Task.sleep(.seconds(2)),
    // a 2_000 ms sleep, a 2e9 ns sleep) instead of going through VisibleRefresh.interval.
    @Test func theOnlyTwoSecondCadenceIsVisibleRefreshInterval() throws {
        let literals = [".seconds(2)", "Duration.seconds(2)", ".milliseconds(2000)", ".milliseconds(2_000)",
                        "2_000_000_000", "2000000000", "TimeInterval(2)", "Timer.publish(every: 2"]
        var offenders: [String] = []
        for file in Self.swiftFiles(under: "App") + Self.swiftFiles(under: "Packages/FlotsamCore/Sources") {
            let code = try Self.code(file)
            for literal in literals where code.contains(literal) { offenders.append("\(file): \(literal)") }
        }
        #expect(offenders == ["Packages/FlotsamCore/Sources/FlotsamBase/Settings/VisibleRefresh.swift: .seconds(2)"])
    }

    // OC-450b-08. Red if: any App Settings pane or the onboarding view runs its own sleeping loop again.
    @Test func noSettingsOrOnboardingViewRunsItsOwnLoop() throws {
        let files = Self.swiftFiles(under: "App/Flotsam/Settings") + ["App/Flotsam/OnboardingView.swift",
                                                                      "App/Flotsam/OnboardingModel.swift"]
        #expect(files.count >= 12)
        var offenders: [String] = []
        for file in files {
            let code = try Self.code(file)
            for token in ["Task.sleep", "clock.sleep", "while !Task.isCancelled", "Timer.", "AsyncTimerSequence"]
            where code.contains(token) { offenders.append("\(file): \(token)") }
        }
        #expect(offenders == [])
    }

    // OC-450b-09. The call sites are exactly these three, one each (stable identity, count). Red if: a view gains a
    // second modifier (two loops for one view) or a site is dropped (its rows stop refreshing).
    @Test func refreshWhileVisibleHasExactlyTheThreeExpectedCallSites() throws {
        var sites: [String: Int] = [:]
        for file in Self.swiftFiles(under: "App") where !file.hasSuffix("RefreshWhileVisible.swift") {
            let n = Self.count(of: ".refreshWhileVisible", in: try Self.code(file))
            if n > 0 { sites[file] = n }
        }
        #expect(sites == ["App/Flotsam/OnboardingView.swift": 1,
                          "App/Flotsam/Settings/PrivacyPane.swift": 1,
                          "App/Flotsam/Settings/TriggersPane.swift": 1])
    }

    // OC-450b-10. Red if: PermissionRows (one view per row inside a ForEach) starts its own refresh, state or loop
    // again: that is the per-row loop the re-work removed. The group refresh belongs to TriggersPane only.
    @Test func permissionRowsOwnsNoRefreshOrStateAndTriggersPaneOwnsTheRows() throws {
        let code = try Self.code("App/Flotsam/Settings/TriggersPane.swift")
        let rowsView = try #require(code.components(separatedBy: "struct PermissionRows").last?
            .components(separatedBy: "struct TriggersPane").first)
        let pane = try #require(code.components(separatedBy: "struct TriggersPane").last)

        #expect(!rowsView.contains("refreshWhileVisible"))
        #expect(!rowsView.contains(".task"))
        #expect(!rowsView.contains("@State"))
        #expect(rowsView.contains("let rows: [PermissionRow]"))
        #expect(pane.contains("@State private var rows"))
        #expect(pane.contains("PermissionRows(probe: model.env.permissions, rows: rows)"))
        #expect(Self.count(of: "refreshWhileVisible", in: pane) == 1)
        #expect(pane.contains("rows = PermissionRow.current(probe: model.env.permissions)"))
    }

    // OC-450b-11. Red if: the modifier re-implements the visibility rule or its own loop instead of VisibleRefresh
    // (Rule 9: one home for the rule and the cadence), or stops refreshing on app activation (FR-008-13 b).
    @Test func theModifierDelegatesTheRuleAndTheLoopToVisibleRefresh() throws {
        let code = try Self.code("App/Flotsam/Settings/RefreshWhileVisible.swift")
        #expect(Self.count(of: "VisibleRefresh.isVisible(", in: code) == 1)
        #expect(Self.count(of: "occlusionState", in: code) == 1)
        #expect(code.contains("VisibleRefresh(refresh: refresh)"))
        #expect(code.contains("NSApplication.didBecomeActiveNotification"))
        #expect(!code.contains("Task {") && !code.contains("Task.sleep") && !code.contains("Timer"))
    }
}
