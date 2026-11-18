import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamTriggers

// FRD-005 8T contract tests, gap sweep (the OC ids of .claude/oracle/frd-005-contract.json that no other FRD005ContractTests*
// file names). Each OC below either has a test here, or a citation of an existing exact-asserting test, or an
// UNTESTABLE-AT-PACKAGE line with the missing seam. Expected values are literals.
//
// Citations (existing tests whose assertions already pin the oracle's `then`):
//   OC-5063  TriggerEngine requests a missing permission only from userDidSaveTrigger / userDidEnableTriggers, so
//            launch and the watchdog never prompt: FRD005ContractTestsEngine `oc5064InputMonitoringOff`
//            (`permissions.requested.isEmpty` after start) and `oc5068PromptAtFirstTrigger`.
//   OC-5076, 5077, 5078, 5079, 5081, 5082, 5083  word buffer, reset keys, idle timeout, app change:
//            TriggerMatcherAdversarialTests (aResetRequestIsConsumedOnceAndDoesNotClearLaterWords and neighbours).
//   OC-5085 (Space half), 5086, 5087 (matcher half)  TriggerMatcherAdversarialTests
//            (everyBoundaryKeyMatchesAndIsRecordedAsTheOneThatEndedTheWord, aModifiedBoundaryKeyPassesAndEndsTheWordWithoutAMatch);
//            the engine-level consume/pass decisions and the posted keys are asserted below.
//   OC-5101, 5102  TriggerExpanderAdversarialTests (restore and template paths of the expander).
//   OC-5103  Worf434PasteGateTriggerTests `untrustedExpansionIsCopyOnly`.
//   OC-5104  TriggerExpanderAdversarialTests `aClipboardOfExactlyThirtyTwoMiBIsHeldAndRestored`.
//   OC-5105  TriggerExpanderTests `clipboardIsNotRestoredWhenAnotherAppCopiedInTheWindow` (another app writes during
//            restoreDelay: plainText == "copied meanwhile", writes.count == 1) and TriggerExpanderAdversarialTests
//            `aCopyOfIdenticalTextStillBlocksTheRestore`.
//   OC-5106  TriggerExpanderAdversarialTests `aClipboardOneByteOverThirtyTwoMiBIsNotHeldAndNotRestored`.
//   OC-5108  TriggerPrivacyTests `aConcealedOrTransientClipboardIsNeverReadAndNeverRestored`.
//            [Spec Drift] the oracle's `then` for OC-5108 predates FR-005-16 (a concealed clipboard is neither read nor
//            restored); the test follows the FRD. Surfaced to Ryan, not edited.
//
// UNTESTABLE-AT-PACKAGE OC-5100: external listen-only CGEventTap inter-event timing (<= 10 ms) needs a real second
//   process observing the event stream; the logic half (no inserted sleeps beyond settle and restoreDelay) is asserted
//   by the expander `slept == [settle, restoreDelay]` tests (TriggerExpanderTests, TriggerExpanderAdversarialTests).
// UNTESTABLE-AT-PACKAGE OC-5098 (real-app half): Messages' compose field and its "Return sends" behavior need the real
//   app; the engine half (Return consumed, backspaces posted, one paste, one paste count) is asserted below.
// UNTESTABLE-AT-PACKAGE OC-5120 (real-app half): rich TextEdit rendering of the inserted text needs a real
//   NSTextView; the pasteboard half (which representations an expansion writes) is asserted below.
// UNTESTABLE-AT-PACKAGE OC-5086 (real-app half): "no line break is added" in a real document; the posted-key half
//   (no boundary repost after a keypad-Enter expansion) is asserted below.

@MainActor
@Suite("FRD-005 contract: gap sweep (trigger engine and expander)", .serialized, .timeLimit(.minutes(2)))
struct FRD005ContractTestsGaps {
    private let itemId = ExpanderHarness.itemId

    private func harness(
        triggers: [UUID: String]? = nil, base: ExpanderHarness = ExpanderHarness()
    ) -> EngineHarness {
        EngineHarness(triggers: triggers ?? [itemId: ";sig"], base: base)
    }

    private func typeAndSpace(_ h: EngineHarness) -> [KeyDecision] {
        h.source.type(";sig") + [h.source.press(TriggerKeys.space, " ")]
    }

    // MARK: OC-5125 sleep and wake clears the word

    @Test("OC-5125 ';si', sleep and wake, 'g' Space: no expansion; then ';sig' Space expands")
    func oc5125WakeClearsTheWord() async {
        // given trigger ';sig' and the user has typed ';si'
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        let first = h.source.type(";si")
        #expect(first == [.pass, .pass, .pass])
        // when the Mac sleeps and wakes, then the user types 'g' Space
        await h.engine.systemDidResume()
        let g = h.source.type("g")
        let space = h.source.press(TriggerKeys.space, " ")
        // then the half word is gone: nothing expanded and both keys reached the app
        #expect(g == [.pass])
        #expect(space == .pass)
        #expect(h.base.store.recorded.isEmpty)
        #expect(h.base.pasteboard.writes.isEmpty)
        #expect(h.base.keys.actions.isEmpty)
        // and a whole ';sig' Space afterwards expands exactly once (control: the engine still works after the wake)
        #expect(typeAndSpace(h) == [.pass, .pass, .pass, .pass, .consume])
        #expect(await eventually { h.base.store.recorded == [itemId] })
        // one expansion write, then the user's previous clipboard restored (two writes, none from the half word)
        #expect(await eventually { h.base.pasteboard.writes.count == 2 })
        #expect(h.base.pasteboard.plainText == "previous clipboard")
    }

    @Test("OC-5125 without a wake the same ';si' 'g' Space does expand (the wake is what cleared it)")
    func oc5125ControlWithoutWake() async {
        // given trigger ';sig', ';si' typed
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        h.source.type(";si")
        // when no wake happens and the user types 'g' Space
        h.source.type("g")
        let space = h.source.press(TriggerKeys.space, " ")
        // then it expands: the half-word survives on its own
        #expect(space == .consume)
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    // MARK: OC-5126 Notice throttle across 30 s

    @Test("OC-5126 two disablements 30 s apart re-enable twice and leave exactly one TRG-OS-003 Notice")
    func oc5126ThrottledNotice() async {
        // given trigger ';sig' and a running tap
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        // when macOS disables the tap, and 30 s later disables it again (both clocks move: the health window and the
        // reporter's 60 s throttle read different clocks)
        h.source.simulateDisable()
        #expect(await eventually { h.noticeCodes == [.trgOs003] })
        h.clock.advance(30)
        h.base.clock.advance(30)
        h.source.simulateDisable()
        #expect(await eventually { h.source.reenableCount == 2 })
        // let the second event's reporting finish before counting
        try? await Task.sleep(for: .milliseconds(100))
        // then exactly one Notice exists, the tap was re-enabled twice and is not latched
        #expect(h.noticeCodes == [.trgOs003])
        #expect(h.source.reenableCount == 2)
        #expect(h.engine.status == .running)
        #expect(!h.engine.showsWarningDot)
        // and the throttle is a window, not a latch: a disablement 70 s later shows a new Notice
        h.clock.advance(70)
        h.base.clock.advance(70)
        h.source.simulateDisable()
        #expect(await eventually { h.source.reenableCount == 3 })
        #expect(await eventually { h.noticeCodes.count == 2 })
        #expect(h.noticeCodes == [.trgOs003, .trgOs003])
    }

    // MARK: OC-5086 / OC-5098 Return and keypad Enter expand with no line break

    @Test(
        "OC-5086 / OC-5098 ';sig' then Return or keypad Enter: key consumed, item pasted once, no boundary key re-posted",
        arguments: [(TriggerKeys.returnKey, "\r", "Return"), (TriggerKeys.keypadEnter, "\r", "keypad Enter")])
    func oc5086ReturnAndEnterExpand(code: UInt16, characters: String, name: String) async {
        // given trigger ';sig' with an ordinary editor in front
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        // when the user types ';sig' and the boundary key is \(name)
        let word = h.source.type(";sig")
        let boundary = h.source.press(code, characters)
        // then the word passed, the boundary key was swallowed (so the app inserts no line break or send)
        #expect(word == [.pass, .pass, .pass, .pass])
        #expect(boundary == .consume, "\(name)")
        // and the item was pasted once (paste count +1, identity), the typed word deleted, and no key re-posted
        #expect(await eventually { h.base.store.recorded == [itemId] })
        #expect(h.base.keys.actions == [.key(TriggerKeys.backspace, count: 4), .paste], "\(name)")
        #expect(await eventually { h.base.pasteboard.writes.count == 2 })
        #expect(h.base.pasteboard.plainText == "previous clipboard", "\(name)")
    }

    // MARK: OC-5087 a non-matching Return passes through

    @Test("OC-5087 'hello' then Return is not a trigger: Return passes, nothing expands, no key is posted")
    func oc5087NonMatchingReturnPasses() async {
        // given trigger ';sig' and a chat field where Return sends
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        // when the user types 'hello' Return
        let word = h.source.type("hello")
        let boundary = h.source.press(TriggerKeys.returnKey, "\r")
        // then every key including Return reached the app and Flotsam did nothing
        #expect(word == [.pass, .pass, .pass, .pass, .pass])
        #expect(boundary == .pass)
        #expect(h.base.store.recorded.isEmpty)
        #expect(h.base.pasteboard.writes.isEmpty)
        #expect(h.base.keys.actions.isEmpty)
        #expect(h.base.presenter.huds.isEmpty)
        // control: the same Return after ';sig' is the one that expands
        h.source.type(";sig")
        #expect(h.source.press(TriggerKeys.returnKey, "\r") == .consume)
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    // MARK: OC-5085 modified boundary keys

    @Test("OC-5085 ';sig' with Shift-Return and ';sig' with Option-Space pass through untouched; a later ';sig' Space expands")
    func oc5085ModifiedBoundaryKeysPass() async {
        // given trigger ';sig' in a chat field where Shift-Return inserts a newline
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        // when the user types ';sig' Shift-Return
        h.source.type(";sig")
        let shiftReturn = h.source.send(KeyEvent(kind: .keyDown, keyCode: TriggerKeys.returnKey, flags: [.shift], characters: "\r"))
        // then no expansion and the key passed through
        #expect(shiftReturn == .pass)
        #expect(h.base.store.recorded.isEmpty)
        #expect(h.base.keys.actions.isEmpty)
        // and separately ';sig' Option-Space
        h.source.type(";sig")
        let optionSpace = h.source.send(KeyEvent(kind: .keyDown, keyCode: TriggerKeys.space, flags: [.option], characters: " "))
        #expect(optionSpace == .pass)
        #expect(h.base.store.recorded.isEmpty)
        #expect(h.base.pasteboard.writes.isEmpty)
        // control: an unmodified Space after a fresh ';sig' does expand, once
        #expect(typeAndSpace(h) == [.pass, .pass, .pass, .pass, .consume])
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    // MARK: OC-5066 Accessibility off

    @Test("OC-5066 Accessibility off, Input Monitoring on: no tap, ';sig' Space passes, SET-PRM-001 is reported")
    func oc5066AccessibilityOff() async {
        // given an item with ';sig', Input Monitoring granted, Accessibility not granted
        let h = harness()
        h.base.permissions.set(.accessibility, granted: false)
        // when the user types ';sig' Space
        await h.engine.start()
        defer { h.engine.stop() }
        let decisions = typeAndSpace(h)
        // then no tap exists and every key reached the app
        #expect(h.engine.status == .inert([.setPrm001]))
        #expect(h.source.startCount == 0)
        #expect(!h.source.isInstalled)
        #expect(decisions == [.pass, .pass, .pass, .pass, .pass])
        #expect(h.base.store.recorded.isEmpty)
        #expect(h.base.pasteboard.writes.isEmpty)
        #expect(h.base.keys.actions.isEmpty)
        // and SET-PRM-001 is reported (once)
        #expect(await eventually { h.noticeCodes == [.setPrm001] })
        #expect(await h.base.reportedCodes() == [.setPrm001])

        // control: granting it on the next watchdog pass creates the tap
        h.base.permissions.set(.accessibility, granted: true)
        h.runWatchdogPass()
        #expect(await eventually { h.engine.status == .running })
        #expect(h.source.startCount == 1)
    }

    // MARK: OC-5120 what an expansion writes for a plain and a link item

    @Test("OC-5120 a plain-text item and a link item each write their text as plain text, nothing rich")
    func oc5120PlainAndLinkWritePlainText() async {
        // given a plain item "unformatted" and a link item "https://e.com" with a public.url representation
        let plain = ExpanderHarness(
            content: .success(ItemContent(kind: .text, plainText: "unformatted", representations: [], members: [])))
        let link = ExpanderHarness(
            content: .success(
                ItemContent(
                    kind: .link, plainText: "https://e.com",
                    representations: [PasteboardRepresentation(uti: "public.url", data: Data("https://e.com".utf8))],
                    members: [])))
        // when each is expanded
        let plainOutcome = await plain.expander.expand(plain.match())
        let linkOutcome = await link.expander.expand(link.match())
        // then both expanded once, and the written plain text is exactly the item text
        #expect(plainOutcome == .expanded)
        #expect(linkOutcome == .expanded)
        // (each made two writes: the expansion, then the restore of the previous clipboard; the expansion is first)
        #expect(plain.pasteboard.writes.count == 2)
        #expect(link.pasteboard.writes.count == 2)
        func text(_ h: ExpanderHarness) -> String? {
            h.pasteboard.writes[0].first { $0.uti == "public.utf8-plain-text" }.flatMap { String(data: $0.data, encoding: .utf8) }
        }
        #expect(text(plain) == "unformatted")
        #expect(text(link) == "https://e.com")
        // and neither wrote a rich-text representation (no RTF, no HTML): nothing the app could render as formatting
        for h in [plain, link] {
            let types = h.pasteboard.writes[0].map(\.uti)
            #expect(!types.contains("public.rtf"), "\(types)")
            #expect(!types.contains("public.html"), "\(types)")
        }
    }
}
