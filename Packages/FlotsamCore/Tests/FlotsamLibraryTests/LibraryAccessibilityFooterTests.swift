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
