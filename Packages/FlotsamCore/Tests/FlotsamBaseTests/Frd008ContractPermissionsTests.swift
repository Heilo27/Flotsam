import Foundation
import Testing

@testable import FlotsamBase

// FRD-008 contract tests, Phase 8T part B: permissions and login item (OC-8103 to OC-8125), pure-model parts.
//
// NO SEAM: MANUAL (needs the OS, the App target, or a module FlotsamBaseTests cannot link):
//   OC-8109 (end-to-end copy / hotkey / search / shelf / screenshot with permissions revoked), OC-8112 (double-click is
//   Library UI), OC-8113 and OC-8118 footer hint and Enable button (FlotsamLibrary + App), OC-8114 (Library search /
//   preview / edit), OC-8116 (Carbon hotkey needs a live key event), OC-8117 expansion half (FlotsamTriggers), OC-8105
//   row flip within 2 s (pasteboard probe is App/Platform), OC-8106 button opens the matching pane (view code),
//   OC-8108 real paste into TextEdit, OC-8124 Login Items removal in System Settings.

/// Records every prompt and Settings jump; grants are mutable so one probe can model a user changing System Settings.
final class Frd008Probe: PermissionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Set<PermissionKind>
    private(set) var requests: [PermissionKind] = []
    private(set) var opened: [PermissionKind] = []
    init(granted: Set<PermissionKind> = []) { self.granted = granted }
    func set(_ kind: PermissionKind, _ on: Bool) {
        lock.withLock { if on { granted.insert(kind) } else { granted.remove(kind) } }
    }
    func isGranted(_ kind: PermissionKind) -> Bool { lock.withLock { granted.contains(kind) } }
    func request(_ kind: PermissionKind) { lock.withLock { requests.append(kind) } }
    func openSystemSettings(_ kind: PermissionKind) { lock.withLock { opened.append(kind) } }
}

/// Repo root, found by walking up from this file to `project.yml`.
private func frd008RepoRoot() -> URL? {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) { return url }
        url.deleteLastPathComponent()
    }
    return nil
}

@MainActor
private struct Rig {
    let clock = ManualClock()
    let presenter = RecordingPresenter()
    let sink = RecordingLogSink()
    let reporter: ErrorReporter
    init() { reporter = ErrorReporter(presenter: presenter, clock: clock, sink: sink) }
}

@Suite("FRD-008 contract: permissions and login item")
struct Frd008ContractPermissionsTests {
    // OC-8103. Red if rows are cached or read from a stored copy instead of the probe at the time of the call.
    @Test("OC-8103: the Accessibility row follows the live grant: Granted, Not granted, Granted again")
    func accessibilityRowFollowsProbe() {
        let probe = Frd008Probe(granted: [.accessibility])
        func accessibility() -> String? {
            PermissionRow.current(probe: probe).first { $0.kind == .accessibility }?.status.text
        }
        #expect(accessibility() == "Granted")
        probe.set(.accessibility, false)
        #expect(accessibility() == "Not granted")
        probe.set(.accessibility, true)
        #expect(accessibility() == "Granted")
    }

    // OC-8104. Red if revoking Input Monitoring changes the wrong row or is not reflected.
    @Test("OC-8104: revoking Input Monitoring flips only its row")
    func inputMonitoringRowFlipsAlone() {
        let probe = Frd008Probe(granted: [.accessibility, .inputMonitoring])
        probe.set(.inputMonitoring, false)
        let rows = PermissionRow.current(probe: probe)
        #expect(rows.count == 2)
        #expect(rows.map(\.kind) == [.accessibility, .inputMonitoring])
        #expect(rows.map { $0.status.text } == ["Granted", "Not granted"])
    }

    // OC-8105 (notice half). Red if CAP-PRM-001 stops raising a Notice with this message, or the notice stays after
    // the capture path clears it on Allow. Warning dot is `!notices.isEmpty` (App/Flotsam/ErrorPresenterAdapter).
    @MainActor
    @Test("OC-8105: CAP-PRM-001 adds exactly one Notice with the guidance text and clears when allowed")
    func pasteboardBlockedNotice() async {
        let rig = Rig()
        #expect(rig.presenter.notices.isEmpty)
        await rig.reporter.report(FlotsamError(.capPrm001, "blocked"), origin: .background)
        #expect(rig.presenter.notices.count == 1)
        #expect(rig.presenter.notices.map(\.code) == [.capPrm001])
        #expect(rig.presenter.notices.map(\.message) == [
            "macOS is blocking Flotsam from reading copied items. Allow Flotsam under Paste from Other Apps in System Settings."
        ])
        // when allowed, the capture path clears the code
        await rig.reporter.clearNotices(code: .capPrm001)
        #expect(rig.presenter.notices.isEmpty)
    }

    // OC-8106. Red if a row loses its text status, its explanation, or two states render the same text.
    @Test("OC-8106: each permission row shows Granted or Not granted as text plus what it enables")
    func rowsCarryTextStatusAndPurpose() {
        let denied = PermissionRow.current(probe: Frd008Probe())
        let allowed = PermissionRow.current(probe: Frd008Probe(granted: [.accessibility, .inputMonitoring]))
        #expect(denied.map { $0.status.text } == ["Not granted", "Not granted"])
        #expect(allowed.map { $0.status.text } == ["Granted", "Granted"])
        #expect(denied.map { $0.name.text } == ["Accessibility", "Input Monitoring"])
        #expect(denied.map { $0.enables.text } == [
            "Lets Flotsam paste into the app you are using.",
            "Lets triggers notice the text you type. Flotsam never stores keystrokes.",
        ])
        #expect(denied.map(\.id) == [.accessibility, .inputMonitoring])
    }

    // OC-8107, OC-8145. Red if any model that decides from permission state calls request() (a system prompt).
    @Test("OC-8107/8145: reading permission state, relaunched three times, never prompts")
    func readingStateNeverPrompts() {
        for _ in 0..<3 {
            let probe = Frd008Probe()  // a relaunch: every permission declined
            _ = PermissionRow.current(probe: probe)
            _ = PasteGate.isAllowed(probe: probe)
            _ = TriggerPermissionNotice.missing(triggersEnabled: true, probe: probe)
            #expect(probe.requests.isEmpty)
            #expect(probe.opened.isEmpty)
        }
    }

    // OC-8108. Red if state is carried over from a previous launch rather than read from the probe.
    @Test("OC-8108: a launch after Accessibility was granted while quit reads Granted and pastes")
    func grantWhileQuitIsSeenAtLaunch() {
        let before = Frd008Probe()
        #expect(!PasteGate.isAllowed(probe: before))
        let afterRelaunch = Frd008Probe(granted: [.accessibility])
        #expect(PermissionRow.current(probe: afterRelaunch).first?.status.text == "Granted")
        #expect(PasteGate.isAllowed(probe: afterRelaunch))
        #expect(afterRelaunch.isAccessibilityTrusted)
    }

    // OC-8110. FR-008-13: Accessibility is requested at the first paste attempt. Red if the paste service stops calling
    // request(.accessibility) on the paste path. Source scan only: the once-only half needs a behavioural test (Worf).
    @Test("OC-8110: the first paste attempt with Accessibility off prompts once")
    func firstPasteAttemptRequestsAccessibility() throws {
        let root = try #require(frd008RepoRoot())
        let source = try String(
            contentsOf: root.appendingPathComponent("Packages/FlotsamCore/Sources/FlotsamPaste/PasteService.swift"),
            encoding: .utf8)
        #expect(source.contains("request(.accessibility)"))
    }

    // OC-8111, OC-8119. Red if the copy-only HUD text drifts or the HUD is not shown for the first denied choice.
    @MainActor
    @Test("OC-8111/8119: choosing an item with Accessibility off shows the exact copy-only HUD")
    func copyOnlyHUD() async {
        let rig = Rig()
        #expect(!PasteGate.isAllowed(probe: Frd008Probe()))
        #expect(PasteGate.copyOnlyError() == FlotsamError(.setPrm001, "Accessibility not granted; pasting by copy only"))
        await rig.reporter.report(FlotsamError(.setPrm001, "copied only"), origin: .userInitiated)
        #expect(rig.presenter.huds == [
            "Accessibility is off, so Flotsam can't paste for you. The item is on your clipboard; press ⌘V."
        ])
        // negative: granted never copy-only
        #expect(PasteGate.isAllowed(probe: Frd008Probe(granted: [.accessibility])))
    }

    // OC-8115. Red if a single choice can show more than one HUD, or the first denied choice shows none.
    @MainActor
    @Test("OC-8115: three choices within 20 s show at most one HUD each and the first shows one")
    func repeatedChoicesShowAtMostOneHUD() async {
        let rig = Rig()
        var deltas: [Int] = []
        for _ in 0..<3 {
            let before = rig.presenter.huds.count
            await rig.reporter.report(FlotsamError(.setPrm001, "copied only"), origin: .userInitiated)
            deltas.append(rig.presenter.huds.count - before)
            rig.clock.advance(by: 5)
        }
        #expect(deltas.allSatisfy { $0 <= 1 })
        #expect(deltas.first == 1)
        #expect(rig.presenter.fatals.isEmpty)
    }

    // OC-8117 (notice half). Red if the Triggers pane stops naming the missing permission.
    @Test("OC-8117: triggers on with Accessibility off names SET-PRM-001 only; both off names both; triggers off names none")
    func triggerNoticeNamesMissingPermission() {
        let inputOnly = Frd008Probe(granted: [.inputMonitoring])
        #expect(TriggerPermissionNotice.missing(triggersEnabled: true, probe: inputOnly) == [.setPrm001])
        #expect(TriggerPermissionNotice.missing(triggersEnabled: true, probe: Frd008Probe()) == [.setPrm001, .setPrm002])
        #expect(TriggerPermissionNotice.missing(triggersEnabled: false, probe: Frd008Probe()).isEmpty)
        #expect(TriggerPermissionNotice.missing(
            triggersEnabled: true, probe: Frd008Probe(granted: [.accessibility, .inputMonitoring])).isEmpty)
    }

    // OC-8118 (model half). Red if grant detection needs a relaunch, i.e. the decision is cached.
    @Test("OC-8118: granting Accessibility while running flips the decision from copy-only to paste")
    func grantWithoutRelaunch() {
        let probe = Frd008Probe()
        #expect(!PasteGate.isAllowed(probe: probe))
        probe.set(.accessibility, true)
        #expect(PasteGate.isAllowed(probe: probe))
    }

    // The production paste path (PasteService, Library, Shelf, item hotkeys) never calls PasteGate: it is dead code and
    // the decision is re-implemented at four call sites (Rule 9). Red-until PasteGate is the one home or is removed.
    @Test("Rule 9: PasteGate is the single Accessibility decision used by production paths")
    func pasteGateHasProductionCallSite() throws {
        let root = try #require(frd008RepoRoot())
        let sources = root.appendingPathComponent("Packages/FlotsamCore/Sources")
        var uses = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            if url.lastPathComponent == "Permissions.swift" { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains("PasteGate.") { uses += 1 }
        }
        #expect(uses >= 1)
    }

    // OC-8120, OC-8125. Red if register is called without setEnabled, or setEnabled(true) fails to register.
    @Test("OC-8120/8125: only the switch registers; constructing and reading never does")
    func onlyTheSwitchRegisters() throws {
        let box = Frd008LoginService.Box(status: .off)
        let controller = LoginItemController(service: Frd008LoginService(box: box))
        for _ in 0..<3 { _ = controller.status; _ = LoginItemPresentation(status: controller.status) }
        #expect(box.registers == 0)
        #expect(box.unregisters == 0)
        #expect(try controller.setEnabled(true).get() == .enabled)
        #expect(box.registers == 1)
        #expect(box.unregisters == 0)
        #expect(LoginItemPresentation(status: controller.status).isOn)
    }

    // OC-8121. Red if approval-pending stops showing as on with the caption and the Login Items button.
    @Test("OC-8121: awaiting approval shows on, the caption, and the Login Items button")
    func approvalPresentation() {
        let pending = LoginItemPresentation(status: .requiresApproval)
        #expect(pending.isOn)
        #expect(pending.caption?.text == "Waiting for approval in System Settings")
        #expect(pending.showsLoginItemsButton)
        // negative: enabled and off show no caption and no button
        let enabled = LoginItemPresentation(status: .enabled)
        #expect(enabled.isOn && enabled.caption == nil && !enabled.showsLoginItemsButton)
        let off = LoginItemPresentation(status: .off)
        #expect(!off.isOn && off.caption == nil && !off.showsLoginItemsButton)
    }

    // OC-8122. Red if a refused register leaves the switch on, or the SET-OS-001 text drifts.
    @MainActor
    @Test("OC-8122: a refused register reverts to off and the HUD reads the SET-OS-001 message")
    func registerRefused() async throws {
        let box = Frd008LoginService.Box(status: .off)
        box.registerFails = true
        let controller = LoginItemController(service: Frd008LoginService(box: box))
        let result = controller.setEnabled(true)
        guard case .failure(let error) = result else {
            Issue.record("refusal must be a failure")
            return
        }
        #expect(error.code == .setOs001)
        #expect(!LoginItemPresentation(status: controller.status).isOn)
        let rig = Rig()
        await rig.reporter.report(error, origin: .userInitiated)
        #expect(rig.presenter.huds == ["Couldn't change Launch at login. Check System Settings › General › Login Items."])
    }

    // OC-8123. Red if a failed unregister turns the switch off.
    @MainActor
    @Test("OC-8123: a failed unregister keeps the switch on and reports SET-OS-001")
    func unregisterRefused() async {
        let box = Frd008LoginService.Box(status: .enabled)
        box.unregisterFails = true
        let controller = LoginItemController(service: Frd008LoginService(box: box))
        guard case .failure(let error) = controller.setEnabled(false) else {
            Issue.record("refusal must be a failure")
            return
        }
        #expect(error.code == .setOs001)
        #expect(box.unregisters == 1)
        #expect(LoginItemPresentation(status: controller.status).isOn)
        let rig = Rig()
        await rig.reporter.report(error, origin: .userInitiated)
        #expect(rig.presenter.huds.count == 1)
        #expect(rig.presenter.huds.first?.hasPrefix("Couldn't change Launch at login.") == true)
    }

    // OC-8124. Red if the switch is read from a stored copy instead of the service status each time.
    @Test("OC-8124: removing Flotsam from Login Items outside the app reads off at the next look")
    func removedExternallyReadsOff() {
        let box = Frd008LoginService.Box(status: .enabled)
        let controller = LoginItemController(service: Frd008LoginService(box: box))
        #expect(LoginItemPresentation(status: controller.status).isOn)
        box.status = .off  // user removed it in System Settings
        #expect(!LoginItemPresentation(status: controller.status).isOn)
        #expect(!controller.isOn)
    }
}
