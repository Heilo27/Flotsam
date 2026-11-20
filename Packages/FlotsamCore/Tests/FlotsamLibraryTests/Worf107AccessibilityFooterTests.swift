import FlotsamBase
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-107 (Worf, worf-107): FR-008-14 / AC-008-09 / FR-003-17 / OC-8113, OC-8118, OC-3078. Complements the builder's
// LibraryAccessibilityFooterTests. The App target has no test target, so the three App-side wires (button, poll, pane
// anchor, container wiring) are pinned as source-shape checks, the same way Worf397bSourceRulesTests does.

@MainActor
@Suite struct Worf107AccessibilityFooterTests {
    private final class Probe: PermissionProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var granted: Bool
        private var _opened: [PermissionKind] = []
        private var _reads = 0
        init(granted: Bool) { self.granted = granted }
        var opened: [PermissionKind] { lock.withLock { _opened } }
        var reads: Int { lock.withLock { _reads } }
        func set(_ value: Bool) { lock.withLock { granted = value } }
        func isGranted(_ kind: PermissionKind) -> Bool { lock.withLock { _reads += 1; return granted } }
        func request(_ kind: PermissionKind) {}
        func openSystemSettings(_ kind: PermissionKind) { lock.withLock { _opened.append(kind) } }
    }

    private func make(granted: Bool) -> (LibraryViewModel, Probe) {
        let probe = Probe(granted: granted)
        let model = LibraryViewModel(
            source: FakeSource(rows: Harness.rows(2), counts: nil), paster: FakePaster(), host: FakeHost(),
            preferences: FakePreferences(),
            effects: LibraryEffects(
                isAccessibilityTrusted: { probe.isAccessibilityTrusted },
                openAccessibilitySettings: { probe.openSystemSettings(.accessibility) }))
        return (model, probe)
    }

    // OC-8113. Mutation: drop enableLabel (always nil) or hard-wire it; invert the trust test.
    @Test func enableLabelIsExactlyEnableForEverySelectionAndPreviewStateWhileOff() {
        // given Accessibility is off, when the footer is built for 0, 1 and 3 selected rows with preview open and closed
        for selection in [0, 1, 3] {
            for preview in [false, true] {
                let off = LibraryFooter(totalCount: 5, selectionCount: selection, isAccessibilityTrusted: false, sort: .recent)
                // then the button label is the literal "Enable", and is absent once granted
                #expect(off.enableLabel == "Enable", "selection \(selection) preview \(preview)")
                let on = LibraryFooter(totalCount: 5, selectionCount: selection, isAccessibilityTrusted: true, sort: .recent)
                #expect(on.enableLabel == nil, "selection \(selection) preview \(preview)")
            }
        }
        // and FR-003-17: the copy-only text is persistent for single and empty selection, in both preview states
        for selection in [0, 1] {
            for preview in [false, true] {
                let off = LibraryFooter(totalCount: 5, selectionCount: selection, isAccessibilityTrusted: false, sort: .recent)
                #expect(off.notice == "Press ⌘V to paste")
            }
        }
    }

    // Mutation: skip refreshAccessibility() in open(). The revision is the only observable of that call.
    @Test func openReadsAccessibilityFreshAndOnlyBumpsOnChange() async {
        // given a model that has never read Accessibility, trust off
        let (model, probe) = make(granted: false)
        #expect(model.accessibilityRevision == 0)
        // when it opens, then the first read registers (revision 1)
        await model.open(target: nil)
        #expect(model.accessibilityRevision == 1)
        // when it opens again with no change, then there is no spurious re-render
        await model.open(target: nil)
        #expect(model.accessibilityRevision == 1)
        // when the user grants in System Settings and reopens, then the footer is clear and the revision moved by exactly 1
        probe.set(true)
        await model.open(target: nil)
        #expect(model.accessibilityRevision == 2)
        #expect(model.footer().enableLabel == nil)
        #expect(model.footer().notice == nil)
        // when revoked and reopened, then it comes back, revision 3
        probe.set(false)
        await model.open(target: nil)
        #expect(model.accessibilityRevision == 3)
        #expect(model.footer().enableLabel == "Enable")
    }

    // OC-8118. The poll loop `while !refreshAccessibility()`: must read live every call, stop on grant, bump once.
    @Test func pollingReadsLiveEachCallAndBumpsExactlyOnceOnGrant() {
        let (model, probe) = make(granted: false)
        _ = model.refreshAccessibility()
        let rev = model.accessibilityRevision
        let readsBefore = probe.reads
        // given three polls while still off, then no revision movement and a live read each time (never cached)
        for _ in 0..<3 { #expect(!model.refreshAccessibility()) }
        #expect(model.accessibilityRevision == rev)
        #expect(probe.reads == readsBefore + 3)
        // when granted, then the next poll returns true (which ends the loop) and bumps once; further reads do not bump
        probe.set(true)
        #expect(model.refreshAccessibility())
        #expect(model.refreshAccessibility())
        #expect(model.accessibilityRevision == rev + 1)
    }

    // AC-008-09 button: opening the Library must not open Settings or prompt; each click opens the Accessibility pane once.
    @Test func openingTheLibraryDoesNotOpenSettingsAndEachClickOpensTheAccessibilityPaneOnce() async {
        let (model, probe) = make(granted: false)
        await model.open(target: nil)
        #expect(probe.opened.isEmpty)
        model.enableAccessibility()
        #expect(probe.opened == [.accessibility])
        model.enableAccessibility()
        #expect(probe.opened == [.accessibility, .accessibility])
    }

    // MARK: App-side wires (no App test target; source-shape)

    private static let repo: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private func squashed(_ relative: String) throws -> String {
        try String(contentsOf: Self.repo.appendingPathComponent(relative), encoding: .utf8)
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    // Mutation: AppContainer passes .inputMonitoring, or drops the argument (default is a no-op).
    @Test func containerWiresTheEnableButtonToTheAccessibilityPane() throws {
        let text = try squashed("App/Flotsam/AppContainer.swift")
        let right = text.contains("openAccessibilitySettings:{probe.openSystemSettings(.accessibility)}")
        let wrong = text.contains("openAccessibilitySettings:{probe.openSystemSettings(.inputMonitoring)}")
        #expect(right)
        #expect(!wrong)
    }

    // Mutation: swap the two anchors in the real probe.
    @Test func realProbeMapsEachKindToItsOwnPane() throws {
        let text = try squashed("App/Platform/SystemPermissionProbe.swift")
        let ax = text.contains("case.accessibility:anchor=\"Privacy_Accessibility\"")
        let im = text.contains("case.inputMonitoring:anchor=\"Privacy_ListenEvent\"")
        let url = text.contains("x-apple.systempreferences:com.apple.preference.security?\\(anchor)")
        #expect(ax)
        #expect(im)
        #expect(url)
    }

    // Mutation: button not rendered / not calling the model; poll ungated or not using refreshAccessibility.
    @Test func footerViewRendersTheButtonAndPollsOnlyWhileTheFooterOffersIt() throws {
        let text = try squashed("App/Flotsam/Library/LibraryView.swift")
        let button = text.contains("ifletenableLabel=footer.enableLabel{Button(enableLabel){model.enableAccessibility()}")
        // The poll loop lives in the model (`watchAccessibility`, tested in LibraryAccessibilityWatchTests); the view
        // only gates its task on the footer offering Enable and on the panel being shown.
        let poll = text.contains(".task(id:footer.enableLabel!=nil&&model.isShown){guardfooter.enableLabel!=nilelse{return}awaitmodel.watchAccessibility()")
        #expect(button)
        #expect(poll)
    }
}
