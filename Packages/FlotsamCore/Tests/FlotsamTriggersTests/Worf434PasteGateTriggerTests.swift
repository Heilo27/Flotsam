import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamTriggers

// TASK-434 (Worf, blind): typed-trigger expansion through the gate. Contract: OC-5103 / OC-5066 (frd-005), FR-005-14
// step 2, FR-005-15, FR-008-06 (pane). The gate runs BEFORE the item is written, so an untrusted expansion reposts the
// typed boundary key, leaves the user's clipboard untouched and reports SET-PRM-001 (the user typed the text; nothing
// is lost). Whole-sequence behaviour through the real PasteService and TriggerExpander, over fakes on every port.

@MainActor
@Suite("TASK-434 Trigger expansion through PasteGate")
struct Worf434PasteGateTriggerTests {
    private static let space = TriggerKeys.space
    private static let hud = "Accessibility is off, so Flotsam can't paste for you. The item is on your clipboard; press ⌘V."

    /// OC-5103. given Accessibility revoked after the match, when the expansion runs, then it ends `.failed(.setPrm001)`,
    /// no backspace and no ⌘V are posted, only the boundary key is reposted, the user's clipboard is untouched, the item
    /// is not recorded as pasted, one SET-PRM-001 is reported and one HUD is shown with the catalogue sentence. Red if
    /// the step-2 recheck reads a stale/other permission, or the expander proceeds to delete the typed trigger.
    @Test("OC-5103 untrusted: expansion fails with SET-PRM-001 and the typed text is left in place")
    func untrustedExpansionIsCopyOnly() async {
        let h = ExpanderHarness()
        h.permissions.set(.accessibility, granted: false)

        let outcome = await h.expander.expand(h.match())

        #expect(outcome == .failed(.setPrm001))
        #expect(h.keys.actions == [.key(Self.space, count: 1)])
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.pasteboard.plainText == "previous clipboard")
        #expect(h.store.recorded.isEmpty)
        #expect(await h.reportedCodes() == [.setPrm001])
        #expect(h.presenter.huds == [Self.hud])
    }

    /// FR-005-15 log trail. given the untrusted expansion, then exactly one SET-PRM-001 is raised and the log carries a
    /// record whose headline starts with the code. Red if the expander skips the reporter (HUD without a record).
    @Test("OC-5103 untrusted: the failure is raised once and logged under SET-PRM-001")
    func raisedOnceAndLogged() async {
        let h = ExpanderHarness()
        h.permissions.set(.accessibility, granted: false)

        _ = await h.expander.expand(h.match())

        let recent = await h.reporter.recentErrors()
        #expect(recent.count == 1)
        #expect(recent.first?.code == .setPrm001)
        #expect(h.sink.records.filter { $0.headline.hasPrefix(ErrorCode.setPrm001.rawValue) }.count == 1)
    }

    /// FR-005-14 inverse. given Accessibility trusted, then the sequence runs: three backspaces, ⌘V, the item written
    /// once, the previous clipboard restored, the item recorded, nothing reported. Red if the gate returns copy-only for
    /// a trusted probe.
    @Test("trusted: expansion pastes in place of the typed trigger")
    func trustedExpansionPastes() async {
        let h = ExpanderHarness()

        let outcome = await h.expander.expand(h.match())

        #expect(outcome == .expanded)
        #expect(h.keys.actions == [.key(TriggerKeys.backspace, count: 3), .paste])
        #expect(h.pasteboard.writes.count == 2)
        #expect(h.pasteboard.writes[0].first { $0.uti == "public.utf8-plain-text" }
            .flatMap { String(data: $0.data, encoding: .utf8) } == "expanded text")
        #expect(h.pasteboard.plainText == "previous clipboard")
        #expect(h.store.recorded == [ExpanderHarness.itemId])
        #expect(await h.reportedCodes().isEmpty)
        #expect(h.presenter.huds.isEmpty)
    }

    /// FR-008-13 rule b: permission is read fresh per expansion. given an untrusted expansion then a grant, when the
    /// same expander runs again, then the second one pastes. Red if the first answer is cached.
    @Test("fresh read: granting Accessibility between two expansions makes the second one paste")
    func grantBetweenExpansions() async {
        let h = ExpanderHarness()
        h.permissions.set(.accessibility, granted: false)
        let first = await h.expander.expand(h.match())
        h.permissions.set(.accessibility, granted: true)
        let second = await h.expander.expand(h.match())

        #expect(first == .failed(.setPrm001))
        #expect(second == .expanded)
        #expect(await h.reportedCodes() == [.setPrm001])
        #expect(h.store.recorded == [ExpanderHarness.itemId])
    }

    /// FR-008-06 / OC-8038 on the same probe the expander uses. given triggers on and the harness probe denying
    /// Accessibility, then the pane's notice lists SET-PRM-001 and its text is the triggers-paused sentence. Red if the
    /// pane used the HUD text or the probe wiring differed from the paste gate.
    @Test("OC-8038 pane notice on the same probe: triggers-paused sentence, distinct from the HUD sentence")
    func paneNoticeMatchesTheGate() {
        let h = ExpanderHarness()
        h.permissions.set(.accessibility, granted: false)

        let codes = TriggerPermissionNotice.missing(triggersEnabled: true, probe: h.permissions)

        #expect(codes == [.setPrm001])
        #expect(TriggerPermissionNotice.text(for: .setPrm001)
            == "Accessibility is off, so typed triggers are paused. Turn it on in System Settings › Privacy & Security.")
    }
}
