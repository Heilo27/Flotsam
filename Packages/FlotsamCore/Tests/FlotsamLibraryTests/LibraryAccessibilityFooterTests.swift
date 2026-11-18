import FlotsamBase
import Foundation
import Testing
@testable import FlotsamLibrary

/// FR-008-14 / AC-008-09: the copy-only footer's "Enable" button and the after-grant state change. The model is wired
/// to a probe the way `AppContainer` wires the real one: trust from `isAccessibilityTrusted`, the button through
/// `openSystemSettings(.accessibility)`.
@MainActor
@Suite struct LibraryAccessibilityFooterTests {
    private final class FakeProbe: PermissionProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var granted: Bool
        private var _opened: [PermissionKind] = []
        private var _requested: [PermissionKind] = []
        init(granted: Bool) { self.granted = granted }
        var opened: [PermissionKind] { lock.withLock { _opened } }
        var requested: [PermissionKind] { lock.withLock { _requested } }
        func grant() { lock.withLock { granted = true } }
        func revoke() { lock.withLock { granted = false } }
        func isGranted(_ kind: PermissionKind) -> Bool { lock.withLock { granted } }
        func request(_ kind: PermissionKind) { lock.withLock { _requested.append(kind) } }
        func openSystemSettings(_ kind: PermissionKind) { lock.withLock { _opened.append(kind) } }
    }

    private func make(granted: Bool) -> (model: LibraryViewModel, probe: FakeProbe) {
        let probe = FakeProbe(granted: granted)
        let model = LibraryViewModel(
            source: FakeSource(rows: Harness.rows(2), counts: nil), paster: FakePaster(), host: FakeHost(),
            preferences: FakePreferences(),
            effects: LibraryEffects(
                isAccessibilityTrusted: { probe.isAccessibilityTrusted },
                openAccessibilitySettings: { probe.openSystemSettings(.accessibility) }))
        return (model, probe)
    }

    @Test func footerOffersEnableOnlyWhileAccessibilityIsOff() {
        let denied = LibraryFooter(totalCount: 3, selectionCount: 1, isPreviewOpen: false, isAccessibilityTrusted: false, sort: .recent)
        #expect(denied.enableLabel == "Enable")
        #expect(denied.notice == "Press ⌘V to paste")
        let granted = LibraryFooter(totalCount: 3, selectionCount: 1, isPreviewOpen: false, isAccessibilityTrusted: true, sort: .recent)
        #expect(granted.enableLabel == nil)
    }

    @Test func enableButtonOpensTheAccessibilityPaneAndDoesNotPrompt() {
        let (model, probe) = make(granted: false)
        model.enableAccessibility()
        #expect(probe.opened == [.accessibility])
        #expect(probe.requested.isEmpty)
    }

    @Test func grantingWithoutRelaunchClearsTheFooterAndBumpsTheRevision() async {
        let (model, probe) = make(granted: false)
        await model.open(target: nil)
        #expect(model.footer().enableLabel != nil)
        let before = model.accessibilityRevision
        #expect(!model.refreshAccessibility())
        #expect(model.accessibilityRevision == before)  // unchanged read: no re-render

        probe.grant()
        #expect(model.refreshAccessibility())
        #expect(model.accessibilityRevision == before + 1)
        let footer = model.footer()
        #expect(footer.enableLabel == nil)
        #expect(footer.notice == nil)
    }

    @Test func reopeningAfterARevokeShowsTheCopyOnlyFooterAgain() async {
        let (model, probe) = make(granted: true)
        await model.open(target: nil)
        #expect(model.footer().enableLabel == nil)
        probe.revoke()
        await model.open(target: nil)
        #expect(model.footer().enableLabel != nil)
    }
}

@MainActor
@Suite struct LibraryAccessibilityWatchTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func tick() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    private func make(reads: Counter) -> LibraryViewModel {
        LibraryViewModel(
            source: FakeSource(rows: Harness.rows(1), counts: nil), paster: FakePaster(), host: FakeHost(),
            preferences: FakePreferences(),
            effects: LibraryEffects(isAccessibilityTrusted: { reads.tick(); return false }))
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.withLock { raised = true } }
        var isRaised: Bool { lock.withLock { raised } }
    }

    /// Waits for `watch` to return and reports whether it did so on its own, without a cancel. A watch that ignores
    /// `isShown` never returns (the probe stays untrusted), which used to hang the test instead of failing it: the
    /// watchdog cancels it after `guardSeconds` (a hang guard, not a bound any FRD sets) and the answer is `false`.
    private func returnsOnItsOwn(_ watch: Task<Void, Never>, guardSeconds: Double = 10) async -> Bool {
        let timedOut = Flag()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(guardSeconds))
            guard !Task.isCancelled else { return }
            timedOut.raise()
            watch.cancel()
        }
        await watch.value
        watchdog.cancel()
        return !timedOut.isRaised
    }

    /// Waits for `condition` on the event (the probe being read); `guardSeconds` is only a hang guard.
    private func waitFor(guardSeconds: Double = 30, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(guardSeconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return condition()
    }

    @Test func watchDoesNotPollBeforeOpenOrAfterHide() async {
        let reads = Counter()
        let model = make(reads: reads)
        #expect(!model.isShown)
        #expect(await returnsOnItsOwn(Task { await model.watchAccessibility(interval: .milliseconds(1)) }),
                "a watch on a panel that was never shown returns at once")
        #expect(reads.count == 0)

        await model.open(target: nil)
        #expect(model.isShown)
        let afterOpen = reads.count
        model.panelDidHide()
        #expect(!model.isShown)
        #expect(await returnsOnItsOwn(Task { await model.watchAccessibility(interval: .milliseconds(1)) }),
                "a watch on a hidden panel returns at once")
        #expect(reads.count == afterOpen)
    }

    @Test func watchPollsWhileShownAndStopsWhenThePanelHides() async {
        let reads = Counter()
        let model = make(reads: reads)
        await model.open(target: nil)
        let task = Task { await model.watchAccessibility(interval: .milliseconds(5)) }
        // Polls while shown: more than two probe reads (bound unchanged), waited for on the event, not an 80 ms sleep.
        #expect(await waitFor { reads.count > 2 }, "the watch polls while the panel is shown")
        model.panelDidHide()
        // Returns on its own once hidden: no cancel needed. A watch that kept polling is cancelled by the watchdog
        // and fails here instead of hanging the run.
        #expect(await returnsOnItsOwn(task), "the watch stops by itself once the panel hides")
        let settled = reads.count
        // The watch has returned, so nothing may read again; a few turns of the main actor would show a straggler.
        for _ in 0..<20 { await Task.yield() }
        #expect(reads.count == settled)
    }

    @Test func watchEndsOnceAccessibilityIsGranted() async {
        let model = LibraryViewModel(
            source: FakeSource(rows: Harness.rows(1), counts: nil), paster: FakePaster(), host: FakeHost(),
            preferences: FakePreferences(), effects: LibraryEffects(isAccessibilityTrusted: { true }))
        await model.open(target: nil)
        await model.watchAccessibility(interval: .milliseconds(1))
        #expect(model.footer().enableLabel == nil)
    }
}
