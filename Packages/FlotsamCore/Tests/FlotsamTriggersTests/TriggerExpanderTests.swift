import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamTriggers

/// FR-005-14 (sequence) and FR-005-15 (failure handling), against fakes on every port.
@MainActor
@Suite struct TriggerExpanderTests {
    private static let space = TriggerKeys.space
    private let backspace = TriggerKeys.backspace

    // MARK: FR-005-14 sequence

    @Test func successRunsTheSequenceInOrderAndRestoresTheClipboard() async {
        let h = ExpanderHarness()
        let writesWhenBackspacing = LockedValue<Int?>(nil)
        h.keys.onAction = {
            if h.keys.actions.count == 1 {
                let writes = h.pasteboard.writes.count
                writesWhenBackspacing.withLock { $0 = writes }
            }
        }

        let outcome = await h.expander.expand(h.match())

        #expect(outcome == .expanded)
        // Step 5 then step 6, and the boundary key is not re-posted: it is consumed (FR-005-12).
        #expect(h.keys.actions == [.key(backspace, count: 3), .paste])
        // Step 4 happened before step 5.
        #expect(writesWhenBackspacing.value == 1)
        // The item was written with own-write markers, then the previous clipboard was written back.
        #expect(h.pasteboard.writes.count == 2)
        #expect(h.pasteboard.writes[0].map(\.uti).contains(PasteboardMarkers.ownWrite))
        #expect(h.pasteboard.writes[0].first { $0.uti == "public.utf8-plain-text" }.flatMap { String(data: $0.data, encoding: .utf8) } == "expanded text")
        #expect(h.pasteboard.plainText == "previous clipboard")
        // Step 7.
        #expect(h.store.recorded == [ExpanderHarness.itemId])
        // The FR-003-15 settle delay sits between the backspaces and ⌘V; the 300 ms restore delay follows ⌘V.
        #expect(h.clock.slept == [PasteTiming.settle, ClipboardPreserver.restoreDelay])
        #expect(await h.reportedCodes().isEmpty)
        #expect(h.presenter.huds.isEmpty)
    }

    @Test func backspaceCountIsTheTriggerLengthInCharacters() async {
        let h = ExpanderHarness()
        _ = await h.expander.expand(h.match(typed: ";addr1"))
        #expect(h.keys.actions.first == .key(backspace, count: 6))
    }

    @Test func clipboardVariableReadsThePreviousClipboardTakenAtStepThree() async {
        let content = ItemContent(kind: .text, plainText: "Hi {clipboard}!", representations: [], members: [])
        let h = ExpanderHarness(content: .success(content), clipboard: "Ada")
        _ = await h.expander.expand(h.match())
        let text = h.pasteboard.writes[0].first { $0.uti == "public.utf8-plain-text" }.flatMap { String(data: $0.data, encoding: .utf8) }
        #expect(text == "Hi Ada!")
    }

    @Test func clipboardIsNotRestoredWhenAnotherAppCopiedInTheWindow() async {
        let h = ExpanderHarness()
        let pasteboard = h.pasteboard
        let restoreDelay = ClipboardPreserver.restoreDelay
        h.clock.onSleep = { duration in
            if duration == restoreDelay { pasteboard.externalCopy("copied meanwhile") }
        }
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .expanded)
        #expect(h.pasteboard.plainText == "copied meanwhile")
        #expect(h.pasteboard.writes.count == 1)
    }

    @Test func aBookkeepingFailureAfterThePasteIsLoggedNotShown() async {
        let h = ExpanderHarness()
        h.store.recordFailure = FlotsamError(.stoDb004, "forced")
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .expanded)
        #expect(h.presenter.huds.isEmpty)
        #expect(h.sink.records.contains { $0.headline.hasPrefix(ErrorCode.stoDb004.rawValue) })
        // The restore still ran.
        #expect(h.pasteboard.plainText == "previous clipboard")
    }

    // MARK: FR-005-15 steps 1 to 5 fail: nothing deleted, boundary key re-posted

    @Test func aFailedLoadRepostsTheBoundaryKeyOnlyAndShowsAHUD() async {
        let h = ExpanderHarness(content: .failure(FlotsamError(.libIo001, "gone")))
        let outcome = await h.expander.expand(h.match(boundary: TriggerKeys.tab))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions == [.key(TriggerKeys.tab, count: 1)])
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.presenter.huds.count == 1)
        #expect(await h.reportedCodes() == [.trgOs002])
        #expect(h.store.recorded.isEmpty)
    }

    @Test func anUnencodableRichItemFailsBeforeAnythingIsWritten() async {
        let rtf = PasteboardRepresentation(uti: "public.rtf", data: Data("{rtf}".utf8))
        let content = ItemContent(kind: .richText, plainText: "{date}", representations: [rtf], members: [])
        let h = ExpanderHarness(content: .success(content))
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions == [.key(Self.space, count: 1)])
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.presenter.huds.count == 1)
    }

    @Test func aFailedPasteboardWriteDeletesNothing() async {
        let h = ExpanderHarness()
        h.pasteboard.writeFailure = FlotsamError(.trgOs002, "forced")
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions == [.key(Self.space, count: 1)])
        #expect(h.presenter.huds.count == 1)
    }

    @Test func aFailedBackspacePostIsTreatedAsNothingDeleted() async {
        let h = ExpanderHarness()
        h.keys.failKeyPress = true
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .failed(.trgOs002))
        // The first post (the backspaces) failed; the second is the re-posted boundary key.
        #expect(h.keys.actions == [.key(backspace, count: 3), .key(Self.space, count: 1)])
        #expect(!h.keys.actions.contains(.paste))
        #expect(h.presenter.huds.count == 1)
    }

    // MARK: FR-005-15 step 6 fails: trigger text and boundary key re-posted

    @Test func aFailedPasteRetypesTheTriggerThenTheBoundaryKey() async {
        let h = ExpanderHarness()
        h.keys.failPaste = true
        let outcome = await h.expander.expand(h.match(typed: "sig"))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions == [.key(backspace, count: 3), .paste, .text("sig"), .key(Self.space, count: 1)])
        #expect(h.presenter.huds.count == 1)
        // The item stays on the pasteboard, as LIB-OS-001 leaves it, and the user's previous clipboard is not restored.
        #expect(h.pasteboard.writes.count == 1)
        #expect(h.store.recorded.isEmpty)
    }

    @Test func ifTheUserLeftTheAppBeforeAFailedPasteNothingIsRetypedIntoTheNewApp() async {
        let h = ExpanderHarness()
        h.keys.failPaste = true
        let environment = h.environment
        // ⌘V is refused because the app changed under it.
        h.keys.onAction = {
            if h.keys.actions.last == .key(TriggerKeys.backspace, count: 3) {
                environment.frontmost = FrontmostApp(bundleId: "com.example.other", processId: 200)
            }
        }
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .failed(.trgOs002))
        #expect(!h.keys.actions.contains(.text("sig")))
        #expect(h.keys.actions.last != .key(Self.space, count: 1))
        #expect(h.presenter.huds.count == 1)
    }

    // MARK: Step 2 recheck

    @Test func accessibilityRevokedAtStepTwoReportsAPermissionHUDAndRepostsTheKey() async {
        let h = ExpanderHarness()
        h.permissions.set(.accessibility, granted: false)
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .failed(.setPrm001))
        #expect(h.keys.actions == [.key(Self.space, count: 1)])
        #expect(h.pasteboard.writes.isEmpty)
        #expect(await h.reportedCodes() == [.setPrm001])
        #expect(h.presenter.huds.count == 1)
    }

    @Test func secureInputTurningOnDuringTheLoadSuppressesQuietly() async {
        let h = ExpanderHarness()
        let environment = h.environment
        h.store.beforeLoad = { environment.secureInput = true }
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .suppressed(.secureInput))
        #expect(h.keys.actions == [.key(Self.space, count: 1)])
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.presenter.huds.isEmpty)
        #expect(await h.reportedCodes().isEmpty)
        #expect(h.sink.records.contains { $0.headline.hasPrefix(ErrorCode.trgPol001.rawValue) })
    }

    @Test func theAppBecomingExcludedDuringTheLoadSuppressesQuietly() async {
        let h = ExpanderHarness()
        let snapshot = h.snapshot
        h.store.beforeLoad = { snapshot.setExcludedApps(["com.example.editor"]) }
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .suppressed(.excludedApp))
        #expect(h.keys.actions == [.key(Self.space, count: 1)])
        #expect(h.presenter.huds.isEmpty)
        #expect(h.sink.records.contains { $0.headline.hasPrefix(ErrorCode.trgPol002.rawValue) })
    }

    @Test func aChangedFrontmostAppAbortsWithoutRepostingIntoTheWrongApp() async {
        let h = ExpanderHarness()
        let environment = h.environment
        h.store.beforeLoad = { environment.frontmost = FrontmostApp(bundleId: "com.example.other", processId: 200) }
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions.isEmpty)
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.presenter.huds.count == 1)
    }
}
