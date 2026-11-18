import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamTriggers

/// Independent QA cases for `TriggerExpander` and the restore it drives (FR-005-14, FR-005-15, FR-005-16), written
/// against FRD-005 and `.claude/oracle/frd-005-contract.json`. Every expected value is a literal. Fakes on every port:
/// no event tap, no real pasteboard, no keystroke.
///
/// Oracle note: OC-5108 says a Concealed clipboard is "back on the clipboard after the restore". FRD-005 FR-005-16 and
/// section 6 item 6 say the opposite (never read, held or restored; Ryan's privacy-first brief). These tests follow the
/// FRD; the oracle line is stale and is reported as a spec drift, not tested.
@MainActor
@Suite struct TriggerExpanderAdversarialTests {
    private static let space = TriggerKeys.space
    private static let cap = 32 * 1024 * 1024
    private static let plain = "public.utf8-plain-text"
    private static let hud = "Couldn't expand that trigger. Your typed text was left as it was."

    /// Replaces what is on the pasteboard, as another app would, and returns how many writes the fake has recorded so
    /// far (so a test can count only the writes the expansion made).
    @discardableResult
    private func seed(_ h: ExpanderHarness, _ representations: [PasteboardRepresentation]) -> Int {
        _ = h.pasteboard.write(representations)
        return h.pasteboard.writes.count
    }

    private func blob(_ uti: String = "public.tiff", bytes: Int) -> PasteboardRepresentation {
        PasteboardRepresentation(uti: uti, data: Data(count: bytes))
    }

    /// An expander like the harness's, but over a ledger the test holds.
    private func expander(sharing h: ExpanderHarness, ledger: OwnWriteLedger) -> TriggerExpander {
        let preserver = ClipboardPreserver(pasteboard: h.pasteboard, ownWrites: ledger, clock: h.clock)
        let paste = PasteService(
            store: h.store, pasteboard: h.pasteboard, files: NoFiles(), frontmost: EnvironmentFrontmost(environment: h.environment),
            accessibility: h.permissions, keys: h.keys, clock: h.clock, ownWrites: ledger)
        return TriggerExpander(
            store: h.store, pasteboard: h.pasteboard, files: NoFiles(), codec: NoRichText(), preserver: preserver,
            ownWrites: ledger, paste: paste, keys: h.keys, keyboard: h.environment, snapshot: h.snapshot,
            permissions: h.permissions, reporter: h.reporter, clock: h.clock, ownBundleId: "com.example.flotsam",
            calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"), sink: h.sink)
    }

    // MARK: 32 MiB cap (FR-005-16, AC-005-15, OC-5104, OC-5106)

    @Test func aClipboardOfExactlyThirtyTwoMiBIsHeldAndRestored() async {
        // OC-5104 boundary. Given 32 MiB on the clipboard / when a trigger expands / then it is put back, byte for byte.
        // Red if `bytes <= snapshotCap` becomes `<`.
        let h = ExpanderHarness(clipboard: nil)
        let before = seed(h, [blob(bytes: Self.cap)])

        let outcome = await h.expander.expand(h.match())

        #expect(outcome == .expanded)
        #expect(h.pasteboard.writes.count - before == 2)
        #expect(h.pasteboard.writes.last?.first?.uti == "public.tiff")
        #expect(h.pasteboard.writes.last?.first?.data.count == 33_554_432)
        #expect(h.clock.slept == [PasteTiming.settle, ClipboardPreserver.restoreDelay])
    }

    @Test func aClipboardOneByteOverThirtyTwoMiBIsNotHeldAndNotRestored() async {
        // OC-5106 boundary. Given 32 MiB + 1 byte / when a trigger expands / then the expansion's text stays on the clipboard.
        // Red if the cap is raised, removed, or compared with `<=` against cap + 1.
        let h = ExpanderHarness(clipboard: nil)
        let before = seed(h, [blob(bytes: Self.cap + 1)])

        let outcome = await h.expander.expand(h.match())

        #expect(outcome == .expanded)
        #expect(h.pasteboard.writes.count - before == 1)
        #expect(h.pasteboard.plainText == "expanded text")
        // No restore wait either: nothing was held.
        #expect(h.clock.slept == [PasteTiming.settle])
        #expect(h.store.recorded == [ExpanderHarness.itemId])
        // Not an error: the history entry already exists, so nothing is shown.
        #expect(h.presenter.huds.isEmpty)
        #expect(await h.reportedCodes().isEmpty)
    }

    @Test func theCapCountsBytesAcrossEveryRepresentation() async {
        // Given two representations, 16 MiB each (total exactly the cap) / then held; with one more byte, not held.
        let atCap = ExpanderHarness(clipboard: nil)
        let atCapBefore = seed(atCap, [blob("public.tiff", bytes: Self.cap / 2), blob("public.png", bytes: Self.cap / 2)])
        _ = await atCap.expander.expand(atCap.match())
        #expect(atCap.pasteboard.writes.count - atCapBefore == 2)
        #expect(atCap.pasteboard.writes.last?.map(\.uti).prefix(2) == ["public.tiff", "public.png"])

        let over = ExpanderHarness(clipboard: nil)
        let overBefore = seed(over, [blob("public.tiff", bytes: Self.cap / 2), blob("public.png", bytes: Self.cap / 2 + 1)])
        _ = await over.expander.expand(over.match())
        #expect(over.pasteboard.writes.count - overBefore == 1)
        #expect(over.pasteboard.plainText == "expanded text")
    }

    @Test func preserverClassifiesTheCapBoundaryAsHeldThenTooLarge() {
        // Same boundary, read straight off `capture()` so the verdict does not depend on the restore path.
        let clock = ManualClock()
        for (bytes, expected) in [(0, HeldClipboard.Disposition.held), (1, .held), (Self.cap, .held), (Self.cap + 1, .tooLarge)] {
            let pasteboard = ExpansionPasteboard()
            _ = pasteboard.write([blob(bytes: bytes)])
            let preserver = ClipboardPreserver(pasteboard: pasteboard, ownWrites: OwnWriteLedger(), clock: clock)
            #expect(preserver.capture().disposition == expected, "bytes = \(bytes)")
        }
        #expect(ClipboardPreserver.snapshotCap == 33_554_432)
    }

    @Test func anEmptyClipboardHoldsNothingAndTheExpansionIsLeftOnTheClipboard() async {
        // 0 case: given no clipboard at all / then no restore write (an empty write would wipe the user's next copy).
        let h = ExpanderHarness(clipboard: nil)
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .expanded)
        #expect(h.pasteboard.writes.count == 1)
        #expect(h.pasteboard.plainText == "expanded text")
        #expect(h.clock.slept == [PasteTiming.settle])
    }

    // MARK: Restore only if changeCount is unchanged (FR-005-16, OC-5105)

    @Test func aCopyOfIdenticalTextStillBlocksTheRestore() async {
        // Given another app copies the very same text Flotsam wrote / then the count moved, so nothing is restored.
        // Red if the restore compares content instead of changeCount.
        let h = ExpanderHarness()
        let pasteboard = h.pasteboard
        let restoreDelay = ClipboardPreserver.restoreDelay
        h.clock.onSleep = { if $0 == restoreDelay { pasteboard.externalCopy("expanded text") } }

        _ = await h.expander.expand(h.match())

        #expect(h.pasteboard.writes.count == 1)
        #expect(h.pasteboard.changeCount == 2)
        #expect(h.pasteboard.plainText == "expanded text")
    }

    @Test func aCopyDuringTheSettleDelayAlsoBlocksTheRestore() async {
        // Given another app copies between the write and ⌘V / then the restore must not overwrite it either.
        let h = ExpanderHarness()
        let pasteboard = h.pasteboard
        h.clock.onSleep = { if $0 == PasteTiming.settle { pasteboard.externalCopy("copied early") } }

        let outcome = await h.expander.expand(h.match())

        #expect(outcome == .expanded)
        #expect(h.pasteboard.plainText == "copied early")
        #expect(h.pasteboard.writes.count == 1)
    }

    @Test func restoreWritesOnceAndOnlyAfterTheThreeHundredMillisecondWait() async {
        // Given nothing else touched the pasteboard / then exactly one restore write, after one 300 ms wait.
        let h = ExpanderHarness()
        _ = await h.expander.expand(h.match())
        #expect(h.pasteboard.writes.count == 2)
        #expect(h.clock.slept.filter { $0 == .milliseconds(300) }.count == 1)
        #expect(h.pasteboard.plainText == "previous clipboard")
        #expect(h.pasteboard.changeCount == 2)
    }

    @Test func restoreRequiresTheChangeCountToMatchExactly() async {
        // Direct on `restore`: matching count restores; one higher or one lower does not. Red for `==` -> `<=` or `>=`.
        let clock = ManualClock()
        func rig() -> (ExpansionPasteboard, ClipboardPreserver, OwnWriteLedger, HeldClipboard, Int) {
            let pasteboard = ExpansionPasteboard(plainText: "prev")
            let ledger = OwnWriteLedger()
            let preserver = ClipboardPreserver(pasteboard: pasteboard, ownWrites: ledger, clock: clock)
            let capture = preserver.capture()
            let count = (try? ledger.write([PasteboardRepresentation(uti: Self.plain, data: Data("item".utf8))], to: pasteboard).get()) ?? -1
            return (pasteboard, preserver, ledger, capture, count)
        }

        let (matchBoard, matchPreserver, _, matchCapture, matchCount) = rig()
        #expect(await matchPreserver.restore(matchCapture, writeChangeCount: matchCount) == .restored)
        #expect(matchBoard.plainText == "prev")

        let (highBoard, highPreserver, _, highCapture, highCount) = rig()
        #expect(await highPreserver.restore(highCapture, writeChangeCount: highCount + 1) == .changedByAnotherApp)
        #expect(highBoard.plainText == "item")
        #expect(highBoard.writes.count == 1)

        let (lowBoard, lowPreserver, _, lowCapture, lowCount) = rig()
        #expect(await lowPreserver.restore(lowCapture, writeChangeCount: lowCount - 1) == .changedByAnotherApp)
        #expect(lowBoard.plainText == "item")
        #expect(lowBoard.writes.count == 1)
    }

    @Test func theRestoredWriteIsOwnWriteMarkedAndLedgered() async {
        // Given a held clipboard / when restored / then the restore carries both markers (empty data), no duplicate
        // types, and its changeCount is in the ledger so capture will not store the user's old clipboard again.
        let clock = ManualClock()
        let pasteboard = ExpansionPasteboard()
        let ledger = OwnWriteLedger()
        // The previous clipboard already carries Flotsam markers and a duplicate type from an earlier expansion.
        _ = pasteboard.write([
            PasteboardRepresentation(uti: Self.plain, data: Data("A".utf8)),
            PasteboardRepresentation(uti: "public.rtf", data: Data("{rtf}".utf8)),
            PasteboardRepresentation(uti: Self.plain, data: Data("B".utf8)),
            PasteboardRepresentation(uti: PasteboardMarkers.ownWrite, data: Data()),
            PasteboardRepresentation(uti: PasteboardMarkers.autoGenerated, data: Data()),
        ])
        let preserver = ClipboardPreserver(pasteboard: pasteboard, ownWrites: ledger, clock: clock)
        let capture = preserver.capture()
        #expect(capture.disposition == .held)
        let count = (try? ledger.write([PasteboardRepresentation(uti: Self.plain, data: Data("item".utf8))], to: pasteboard).get()) ?? -1

        #expect(await preserver.restore(capture, writeChangeCount: count) == .restored)

        let restore = pasteboard.writes.last ?? []
        #expect(restore.map(\.uti) == [Self.plain, "public.rtf", PasteboardMarkers.autoGenerated, PasteboardMarkers.ownWrite])
        #expect(String(data: restore[0].data, encoding: .utf8) == "A")
        #expect(restore[2].data.isEmpty && restore[3].data.isEmpty)
        #expect(ledger.contains(changeCount: count + 1))
        #expect(!ledger.contains(changeCount: count + 2))
    }

    // MARK: Own-write marker (FR-005-14 step 4, FRD-001 FR-001-03)

    @Test func theExpansionWriteAndTheRestoreWriteBothCarryTheOwnWriteMarkerAndAreLedgered() async {
        // Given a normal expansion / then both pasteboard writes end with the markers and both counts are in the ledger.
        // Red if the expander writes the pasteboard directly instead of through the ledger.
        let h = ExpanderHarness()
        let ledger = OwnWriteLedger()
        let outcome = await expander(sharing: h, ledger: ledger).expand(h.match())

        #expect(outcome == .expanded)
        #expect(h.pasteboard.writes.count == 2)
        for write in h.pasteboard.writes {
            let tail = write.suffix(2)
            #expect(tail.map(\.uti) == [PasteboardMarkers.autoGenerated, PasteboardMarkers.ownWrite])
            #expect(tail.allSatisfy { $0.data.isEmpty })
        }
        #expect(ledger.contains(changeCount: 1))
        #expect(ledger.contains(changeCount: 2))
        // A third change (another app) is not ours.
        #expect(!ledger.contains(changeCount: 3))
    }

    @Test func aFailedPasteLeavesTheItemOnTheClipboardStillOwnWriteMarked() async {
        // After a step-6 failure the item stays, and capture must still recognise it as Flotsam's own write.
        let h = ExpanderHarness()
        h.keys.failPaste = true
        let ledger = OwnWriteLedger()
        _ = await expander(sharing: h, ledger: ledger).expand(h.match())
        #expect(h.pasteboard.writes.count == 1)
        #expect(h.pasteboard.writes[0].map(\.uti).suffix(2) == [PasteboardMarkers.autoGenerated, PasteboardMarkers.ownWrite])
        #expect(ledger.contains(changeCount: 1))
    }

    // MARK: Concealed and Transient never read, held, stored or restored (FR-005-16, OC-5036, OC-5037)

    @Test(arguments: [PasteboardMarkers.concealed, PasteboardMarkers.transient])
    func aMarkedPasteboardIsClassifiedBeforeAnyByteIsRead(marker: String) async {
        // Given a marked clipboard, even a 33 MiB one / then the verdict is `.concealed` with no bytes read and no text.
        // Red if the size or the content is examined before the type list.
        let clock = ManualClock()
        let pasteboard = ExpansionPasteboard()
        _ = pasteboard.write([
            PasteboardRepresentation(uti: Self.plain, data: Data("s3cret".utf8)),
            blob(bytes: Self.cap + 1),
            PasteboardRepresentation(uti: marker, data: Data()),
        ])
        let ledger = OwnWriteLedger()
        let preserver = ClipboardPreserver(pasteboard: pasteboard, ownWrites: ledger, clock: clock)

        let capture = preserver.capture()

        #expect(capture.disposition == .concealed)
        #expect(capture.plainText.isEmpty)
        #expect(pasteboard.snapshotReads == 0)
        #expect(await preserver.restore(capture, writeChangeCount: pasteboard.changeCount) == .nothingHeld)
        #expect(clock.slept.isEmpty)
        #expect(pasteboard.writes.count == 1)
    }

    @Test(arguments: [PasteboardMarkers.concealed, PasteboardMarkers.transient])
    func aMarkerAnywhereInTheTypeListCountsNotJustTheFirstType(marker: String) async {
        // Given the marker is the last of several types / when a trigger expands / then it is still never restored.
        let h = ExpanderHarness(clipboard: "pw-zzz", clipboardTypes: ["public.html", "public.rtf", marker])
        let outcome = await h.expander.expand(h.match())
        #expect(outcome == .expanded)
        #expect(h.pasteboard.snapshotReads == 0)
        #expect(h.pasteboard.writes.count == 1)
        #expect(h.pasteboard.plainText == "expanded text")
        #expect(h.clock.slept == [PasteTiming.settle])
    }

    @Test func autoGeneratedAloneIsNotConcealedAndIsRestoredWithoutItsOldMarker() async {
        // Negative control: only Concealed and Transient suppress the restore (FR-005-16). An auto-generated clipboard
        // is held and put back, with the marker coming from the ledger once, not carried over twice.
        let h = ExpanderHarness(clipboard: "generated", clipboardTypes: [PasteboardMarkers.autoGenerated])
        _ = await h.expander.expand(h.match())
        #expect(h.pasteboard.snapshotReads == 1)
        #expect(h.pasteboard.writes.count == 2)
        #expect(h.pasteboard.plainText == "generated")
        let types = h.pasteboard.writes[1].map(\.uti)
        #expect(types.filter { $0 == PasteboardMarkers.autoGenerated }.count == 1)
    }

    @Test(arguments: [PasteboardMarkers.concealed, PasteboardMarkers.transient])
    func aMarkedClipboardsTextNeverEntersAVariableTheItemOrTheLog(marker: String) async {
        // Given a password on a marked clipboard / when an item with {clipboard} expands / then the secret is in no
        // write, no HUD, no reported error and no log line.
        let content = ItemContent(kind: .text, plainText: "pw=[{clipboard}]", representations: [], members: [])
        let h = ExpanderHarness(content: .success(content), clipboard: "hunter2-qzx", clipboardTypes: [marker])
        _ = await h.expander.expand(h.match())
        let written = h.pasteboard.writes.flatMap { $0 }.compactMap { String(data: $0.data, encoding: .utf8) }.joined(separator: "|")
        #expect(written.contains("pw=[]"))
        #expect(!written.contains("hunter2"))
        #expect(!h.sink.allText.contains("hunter2"))
        #expect(!h.presenter.huds.joined().contains("hunter2"))
    }

    // MARK: Failure re-post uses the actual boundary key (FR-005-15, OC-5099, OC-5101, OC-5103)

    enum BeforeDelete: CaseIterable, Sendable, CustomTestStringConvertible {
        case load, pasteboardWrite, backspacePost, secureInput, excludedApp, accessibilityRevoked
        var testDescription: String { String(describing: self) }
    }

    nonisolated static let boundaries: [UInt16] = [TriggerKeys.space, TriggerKeys.tab, TriggerKeys.returnKey, TriggerKeys.keypadEnter]

    @Test(arguments: BeforeDelete.allCases, boundaries)
    func everyPreDeleteFailureRepostsTheKeyThatWasActuallyTyped(path: BeforeDelete, boundary: UInt16) async {
        // Given a failure in steps 1 to 5 or the step-2 recheck, for each of the four boundary keys / then exactly one
        // key press, of that key, is re-posted, and nothing was deleted or pasted.
        // Red if the re-post uses a fixed Space, or is skipped on any one path.
        let h = ExpanderHarness(
            content: path == .load ? .failure(FlotsamError(.libIo001, "gone")) : .success(
                ItemContent(kind: .text, plainText: "expanded text", representations: [], members: [])))
        switch path {
        case .load: break
        case .pasteboardWrite: h.pasteboard.writeFailure = FlotsamError(.trgOs002, "forced")
        case .backspacePost: h.keys.failKeyPress = true
        case .secureInput: h.environment.secureInput = true
        case .excludedApp: h.snapshot.setExcludedApps(["com.example.editor"])
        case .accessibilityRevoked: h.permissions.set(.accessibility, granted: false)
        }

        let outcome = await h.expander.expand(h.match(typed: ";sig", boundary: boundary))

        let repost = ExpanderHarness.RecordingKey.press(boundary)
        switch path {
        case .backspacePost:
            // The failed post is the backspaces themselves; then the re-post.
            #expect(h.keys.actions == [.key(TriggerKeys.backspace, count: 4), repost])
        default:
            #expect(h.keys.actions == [repost])
        }
        #expect(!h.keys.actions.contains(.paste))
        #expect(h.store.recorded.isEmpty)
        switch path {
        case .secureInput:
            #expect(outcome == .suppressed(.secureInput))
            #expect(h.presenter.huds.isEmpty)
        case .excludedApp:
            #expect(outcome == .suppressed(.excludedApp))
            #expect(h.presenter.huds.isEmpty)
        case .accessibilityRevoked:
            #expect(outcome == .failed(.setPrm001))
            #expect(h.presenter.huds.count == 1)
        default:
            #expect(outcome == .failed(.trgOs002))
            #expect(h.presenter.huds == [Self.hud])
        }
    }

    @Test(arguments: boundaries)
    func aFailedPasteRetypesTheTriggerInTheCaseItWasTypedThenTheActualBoundaryKey(boundary: UInt16) async {
        // OC-5102. Given ";SiG" typed for trigger ";sig" and ⌘V refused / then the text re-typed is ";SiG" (never the
        // stored lowercase form) followed by the key actually pressed.
        let h = ExpanderHarness()
        h.keys.failPaste = true
        let outcome = await h.expander.expand(h.match(typed: ";SiG", boundary: boundary))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions == [.key(TriggerKeys.backspace, count: 4), .paste, .text(";SiG"), .key(boundary, count: 1)])
        #expect(h.presenter.huds == [Self.hud])
        // No second expansion: one ⌘V only, nothing recorded.
        #expect(h.keys.actions.filter { $0 == .paste }.count == 1)
        #expect(h.store.recorded.isEmpty)
    }

    @Test func aFailedRetypeStillRepostsTheBoundaryKeyAndShowsTheHUD() async {
        // Best effort (FR-005-15): the Unicode post failing must not stop the boundary key or the HUD.
        let h = ExpanderHarness()
        h.keys.failPaste = true
        h.keys.failText = true
        let outcome = await h.expander.expand(h.match(typed: ";sig", boundary: TriggerKeys.returnKey))
        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions.suffix(2) == [.text(";sig"), .key(TriggerKeys.returnKey, count: 1)])
        #expect(h.presenter.huds == [Self.hud])
    }

    @Test func theTypedCaseSurvivesFromTheKeyboardThroughTheEngineToTheRepost() async {
        // End to end through the matcher: the user types ";SiG" + Return for trigger ";sig"; ⌘V fails.
        let h = EngineHarness(triggers: [ExpanderHarness.itemId: ";sig"])
        h.base.keys.failPaste = true
        await h.engine.start()
        defer { h.engine.stop() }

        h.source.type(";SiG")
        #expect(h.source.press(TriggerKeys.returnKey, "\r") == .consume)
        #expect(await eventually { !h.base.presenter.huds.isEmpty })

        #expect(h.base.keys.actions == [.key(TriggerKeys.backspace, count: 4), .paste, .text(";SiG"), .key(TriggerKeys.returnKey, count: 1)])
    }

    @Test func theCauseCodeIsLoggedButTheShownErrorIsAlwaysTheExpansionFailure() async {
        // FR-005-15(b). Given a load failing with LIB-IO-001 / then the HUD and reported code are TRG-OS-002 and the
        // log carries the cause code, never the typed text.
        let h = ExpanderHarness(content: .failure(FlotsamError(.libIo001, "gone")))
        _ = await h.expander.expand(h.match(typed: ";zqxsig"))
        #expect(await h.reportedCodes() == [.trgOs002])
        #expect(h.presenter.huds == [Self.hud])
        #expect(h.sink.allText.contains("TRG-OS-002"))
        #expect(h.sink.allText.contains("LIB-IO-001"))
        #expect(!h.sink.allText.contains("zqx"))
    }

    // MARK: No restore after a failure (FR-005-15(e))

    @Test func aStepSixFailureLeavesTheItemOnTheClipboardAndNeverRestores() async {
        // Given ⌘V is refused / then no restore wait, no restore write, the item (not the previous clipboard) is on the
        // pasteboard, no paste bookkeeping and no "matched" log.
        let h = ExpanderHarness()
        h.keys.failPaste = true

        let outcome = await h.expander.expand(h.match())

        #expect(outcome == .failed(.trgOs002))
        #expect(h.pasteboard.plainText == "expanded text")
        #expect(h.pasteboard.writes.count == 1)
        #expect(h.clock.slept == [PasteTiming.settle])
        #expect(h.store.recorded.isEmpty)
        #expect(!h.sink.records.contains { $0.headline.hasPrefix("trigger.matched") })
    }

    @Test func theMatchedLogControlIsPresentOnSuccess() async {
        // Non-vacuity control for the test above: a success does log the matched event and does restore.
        let h = ExpanderHarness()
        _ = await h.expander.expand(h.match())
        #expect(h.sink.records.contains { $0.headline.hasPrefix("trigger.matched") })
        #expect(h.pasteboard.plainText == "previous clipboard")
    }

    @Test func aStepSixFailureBecauseTheUserLeftTheAppNeverRestoresEither() async {
        // Given the user switched app during the settle delay / then ⌘V is abandoned, nothing is re-typed into the new
        // app, the item stays on the clipboard, and the previous clipboard is not restored.
        let h = ExpanderHarness()
        let environment = h.environment
        h.clock.onSleep = { duration in
            if duration == PasteTiming.settle { environment.frontmost = FrontmostApp(bundleId: "com.example.other", processId: 200) }
        }

        let outcome = await h.expander.expand(h.match())

        #expect(outcome == .failed(.trgOs002))
        #expect(h.keys.actions == [.key(TriggerKeys.backspace, count: 3)])
        #expect(h.pasteboard.plainText == "expanded text")
        #expect(h.pasteboard.writes.count == 1)
        #expect(!h.clock.slept.contains(ClipboardPreserver.restoreDelay))
        #expect(h.presenter.huds == [Self.hud])
    }

    @Test func aStepFiveFailureLeavesTheItemOnTheClipboardAndNeverRestores() async {
        // Backspace post failed (nothing deleted): the item was already written at step 4 and stays.
        let h = ExpanderHarness()
        h.keys.failKeyPress = true
        _ = await h.expander.expand(h.match())
        #expect(h.pasteboard.plainText == "expanded text")
        #expect(h.pasteboard.writes.count == 1)
        #expect(!h.clock.slept.contains(ClipboardPreserver.restoreDelay))
    }

    @Test func aStepFourFailureLeavesThePreviousClipboardUntouched() async {
        // OC-5101. Given the pasteboard write fails / then the clipboard still holds 'previous clipboard' and the
        // typed text is as typed.
        let h = ExpanderHarness()
        h.pasteboard.writeFailure = FlotsamError(.trgOs002, "forced")
        _ = await h.expander.expand(h.match())
        #expect(h.pasteboard.plainText == "previous clipboard")
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.keys.actions == [.key(Self.space, count: 1)])
        #expect(h.clock.slept.isEmpty)
    }

    @Test(arguments: BeforeDelete.allCases)
    func nothingAboutThePreviousClipboardIsReadOnAnyFailureBeforeStepThree(path: BeforeDelete) async {
        // The step-2 recheck runs before the snapshot, so a recheck abort must not have touched the clipboard at all;
        // a load failure ends even earlier.
        let h = ExpanderHarness(
            content: path == .load ? .failure(FlotsamError(.libIo001, "gone")) : .success(
                ItemContent(kind: .text, plainText: "expanded text", representations: [], members: [])))
        switch path {
        case .secureInput: h.environment.secureInput = true
        case .excludedApp: h.snapshot.setExcludedApps(["com.example.editor"])
        case .accessibilityRevoked: h.permissions.set(.accessibility, granted: false)
        case .load: break
        case .pasteboardWrite, .backspacePost: return
        }
        _ = await h.expander.expand(h.match())
        #expect(h.pasteboard.snapshotReads == 0)
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.pasteboard.plainText == "previous clipboard")
    }
}

extension ExpanderHarness {
    /// A key press of `code`, once, as `RecordingKeys` records it.
    enum RecordingKey {
        @MainActor static func press(_ code: UInt16) -> RecordingKeys.Action { .key(code, count: 1) }
    }
}
