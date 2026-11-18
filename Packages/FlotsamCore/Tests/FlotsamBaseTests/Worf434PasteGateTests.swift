import Foundation
import Testing
@testable import FlotsamBase

// TASK-434 (Worf, blind): the single home of the Accessibility copy-only decision. Contract: FR-003-17 (frd-003),
// FR-008-06 (frd-008), OC-8038 (pane text), ADR-0005. Expected values are literals only.

private final class W434GateProbe: PermissionProbe, @unchecked Sendable {
    private let accessibility: Bool
    private let inputMonitoring: Bool
    init(accessibility: Bool, inputMonitoring: Bool = true) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }
    func isGranted(_ kind: PermissionKind) -> Bool { kind == .accessibility ? accessibility : inputMonitoring }
    func request(_ kind: PermissionKind) {}
    func openSystemSettings(_ kind: PermissionKind) {}
}

@Suite("TASK-434 PasteGate single source")
struct Worf434PasteGateTests {
    private static let hud = "Accessibility is off, so Flotsam can't paste for you. The item is on your clipboard; press ⌘V."
    private static let pane = "Accessibility is off, so typed triggers are paused. Turn it on in System Settings › Privacy & Security."
    private static let inputMonitoring = "Input Monitoring is off, so typed triggers are paused. Turn it on in System Settings › Privacy & Security."

    /// FR-003-17. given a probe that denies Accessibility, then the gate is copy-only with SET-PRM-001. Red if the gate
    /// ignores the probe, or inverts the branch.
    @Test("untrusted probe gives copy-only SET-PRM-001")
    func untrustedProbe() {
        let outcome = PasteGate.outcome(probe: W434GateProbe(accessibility: false))
        guard case .copyOnly(let error) = outcome else {
            Issue.record("expected copyOnly, got \(outcome)")
            return
        }
        #expect(error.code == .setPrm001)
        #expect(error.context.isEmpty)
    }

    /// FR-003-15 inverse. given a trusted probe, then the gate is `.paste`. Red if the gate always copies.
    @Test("trusted probe gives paste")
    func trustedProbe() {
        #expect(PasteGate.outcome(probe: W434GateProbe(accessibility: true)) == .paste)
    }

    /// Boundary: Input Monitoring is NOT the paste gate. given Accessibility granted and Input Monitoring denied, the
    /// gate still pastes. Red if the gate reads the wrong permission kind.
    @Test("negative: Input Monitoring denied does not block a paste")
    func inputMonitoringIsNotTheGate() {
        #expect(PasteGate.outcome(probe: W434GateProbe(accessibility: true, inputMonitoring: false)) == .paste)
        let denied = PasteGate.outcome(probe: W434GateProbe(accessibility: false, inputMonitoring: true))
        #expect(denied != .paste)
    }

    /// The Bool and probe entry points agree for both inputs. Red if they ever drift (Rule 9).
    @Test("Bool and probe entry points agree")
    func entryPointsAgree() {
        #expect(PasteGate.outcome(accessibilityGranted: true) == PasteGate.outcome(probe: W434GateProbe(accessibility: true)))
        #expect(PasteGate.outcome(accessibilityGranted: false) == PasteGate.outcome(probe: W434GateProbe(accessibility: false)))
    }

    /// FR-003-17 / OC-8119. given an item id, then the error carries it as context so the HUD and log can name the item;
    /// given none, the context is empty. Red if the id is dropped or invented.
    @Test("copyOnlyError carries the item id when given and none when not")
    func errorContext() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let with = PasteGate.copyOnlyError(itemId: id)
        let without = PasteGate.copyOnlyError()
        #expect(with.code == .setPrm001)
        #expect(with.context.count == 1)
        #expect(with.context[.itemId] == .id(id))
        #expect(without.code == .setPrm001)
        #expect(without.context.isEmpty)
    }

    /// error.SET-PRM-001 HUD sentence, verbatim. Red if the catalogue text changes or the code maps elsewhere.
    @Test("the HUD text for SET-PRM-001 is the catalogue sentence")
    func hudText() {
        #expect(FlotsamStrings.message(for: PasteGate.copyOnlyError()) == Self.hud)
    }

    /// FR-008-06 / OC-8038. given triggers on and Accessibility off, the pane lists SET-PRM-001 and its text is the
    /// "triggers are paused" string, NOT the copy-only HUD text. Red if the pane reuses the HUD wording.
    @Test("OC-8038 pane text for SET-PRM-001 is the triggers-paused sentence, not the HUD sentence")
    func paneText() {
        let codes = TriggerPermissionNotice.missing(
            triggersEnabled: true, probe: W434GateProbe(accessibility: false, inputMonitoring: true))
        #expect(codes == [.setPrm001])
        #expect(TriggerPermissionNotice.text(for: .setPrm001) == Self.pane)
        #expect(TriggerPermissionNotice.text(for: .setPrm001) != Self.hud)
    }

    /// FR-008-06. Order is Accessibility then Input Monitoring; Input Monitoring keeps its catalogue text. Red if the
    /// order flips or the second code is swallowed.
    @Test("both permissions missing lists SET-PRM-001 then SET-PRM-002 with their own texts")
    func bothMissing() {
        let codes = TriggerPermissionNotice.missing(
            triggersEnabled: true, probe: W434GateProbe(accessibility: false, inputMonitoring: false))
        #expect(codes == [.setPrm001, .setPrm002])
        #expect(TriggerPermissionNotice.text(for: .setPrm002) == Self.inputMonitoring)
    }

    /// FR-008-06 negative / empty. Triggers off shows nothing even with both denied; both granted shows nothing.
    @Test("negative: triggers off or everything granted lists no missing permission")
    func nothingMissing() {
        #expect(TriggerPermissionNotice.missing(
            triggersEnabled: false, probe: W434GateProbe(accessibility: false, inputMonitoring: false)).isEmpty)
        #expect(TriggerPermissionNotice.missing(
            triggersEnabled: true, probe: W434GateProbe(accessibility: true, inputMonitoring: true)).isEmpty)
    }

    /// Only Input Monitoring missing: SET-PRM-001 must not appear. Red if the Accessibility row is unconditional.
    @Test("only Input Monitoring missing lists only SET-PRM-002")
    func onlyInputMonitoring() {
        let codes = TriggerPermissionNotice.missing(
            triggersEnabled: true, probe: W434GateProbe(accessibility: true, inputMonitoring: false))
        #expect(codes == [.setPrm002])
    }
}
