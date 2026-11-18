import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamTriggers

/// FR-005-20 (AC-005-19): the tap reads keys only to keep the word buffer. What was typed, and what is on the user's
/// clipboard, never reaches a log, a Notice, a HUD or the error history; and a Concealed or Transient clipboard is
/// neither read nor put back. Driven end to end through `TriggerEngine` and a fake tap.
@MainActor
@Suite struct TriggerPrivacyTests {
    private static let trigger = ";zqxsig"
    private static let marker = "hunter2zqxmarker"
    private static let secret = "s3cretzqxpassword"
    private let itemId = ExpanderHarness.itemId

    // MARK: Typed text is never recorded

    @Test func typedWordsAndTheTriggerTextNeverReachTheLogNoticesHUDsOrErrorHistory() async {
        let base = ExpanderHarness(
            content: .success(ItemContent(kind: .text, plainText: "expanded zqxbody", representations: [], members: [])))
        let h = EngineHarness(triggers: [itemId: Self.trigger], base: base)
        await h.engine.start()
        defer { h.engine.stop() }

        // A word that is not a trigger, typed and ended with Space.
        h.source.type(Self.marker)
        #expect(h.source.press(TriggerKeys.space, " ") == .pass)

        // A trigger that expands.
        h.source.type(Self.trigger)
        #expect(h.source.press(TriggerKeys.space, " ") == .consume)
        #expect(await eventually { base.store.recorded == [itemId] })

        // A trigger that fails at the paste (TRG-OS-002 path).
        base.keys.failPaste = true
        h.source.type(Self.trigger)
        #expect(h.source.press(TriggerKeys.space, " ") == .consume)
        #expect(await eventually { base.store.recorded.count == 2 || !base.presenter.huds.isEmpty })

        // A trigger typed in Secure Event Input (TRG-POL-001).
        base.environment.secureInput = true
        h.source.type(Self.trigger)
        #expect(h.source.press(TriggerKeys.space, " ") == .pass)
        base.environment.secureInput = false

        // A trigger typed in an excluded app (TRG-POL-002).
        base.snapshot.setExcludedApps(["com.example.editor"])
        h.source.type(Self.trigger)
        #expect(h.source.press(TriggerKeys.space, " ") == .pass)

        #expect(await eventually { base.sink.allText.contains("TRG-POL-002") })
        let log = base.sink.allText
        // The scan is not vacuous: outcome codes were logged.
        #expect(log.contains("TRG-POL-001"))
        #expect(log.contains("TRG-OS-002"))

        let surfaced = (
            base.presenter.huds + base.presenter.notices.map { String(describing: $0) }
                + (await base.reporter.recentErrors()).map { String(describing: $0) }
        ).joined(separator: "\n")
        for text in [log, surfaced] {
            for typed in [Self.marker, Self.trigger, "zqx", "hunter2"] {
                #expect(!text.localizedCaseInsensitiveContains(typed), "found \"\(typed)\"")
            }
            // Nor the contents of the item that was expanded.
            #expect(!text.contains("expanded"))
        }
    }

    @Test func theTapReadsNothingWhenTriggersAreOffOrInert() async {
        // FR-005-10 / FR-005-20: with no tap there is no key observation at all.
        let off = EngineHarness(triggers: [itemId: Self.trigger], triggersEnabled: false)
        await off.engine.start()
        defer { off.engine.stop() }
        #expect(off.source.type(Self.marker).allSatisfy { $0 == .pass })
        #expect(!off.source.isInstalled)

        let inert = EngineHarness(triggers: [itemId: Self.trigger])
        inert.base.permissions.set(.inputMonitoring, granted: false)
        await inert.engine.start()
        defer { inert.engine.stop() }
        #expect(!inert.source.isInstalled)
        #expect(inert.source.startCount == 0)
    }

    // MARK: Concealed and Transient clipboards

    @Test(arguments: [PasteboardMarkers.concealed, PasteboardMarkers.transient])
    func aConcealedOrTransientClipboardIsNeverReadAndNeverRestored(marker: String) async {
        let base = ExpanderHarness(
            content: .success(ItemContent(kind: .text, plainText: "Hi {clipboard}!", representations: [], members: [])),
            clipboard: Self.secret, clipboardTypes: [marker])
        let h = EngineHarness(triggers: [itemId: Self.trigger], base: base)
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(base.pasteboard.plainText == Self.secret)

        h.source.type(Self.trigger)
        #expect(h.source.press(TriggerKeys.space, " ") == .consume)
        #expect(await eventually { base.store.recorded == [itemId] })
        // Restore follows the bookkeeping with no sleep of its own when nothing is held, so a wrongly attempted restore
        // would land within moments; give it a grace period before asserting it never happened.
        try? await Task.sleep(for: .milliseconds(100))

        // Never read: the pasteboard's bytes were not requested, only its type identifiers.
        #expect(base.pasteboard.snapshotReads == 0)
        // Never restored: the only write is the expansion itself, and the secret is nowhere in it.
        #expect(base.pasteboard.writes.count == 1)
        let written = base.pasteboard.writes[0].compactMap { String(data: $0.data, encoding: .utf8) }.joined()
        #expect(written.contains("Hi !"))
        #expect(!written.contains(Self.secret))
        #expect(base.pasteboard.plainText != Self.secret)
        // And not logged.
        #expect(!base.sink.allText.contains(Self.secret))
    }

    @Test func anOrdinaryClipboardIsReadOnceAndRestored() async {
        // The control for the test above: the same flow with no marker does read and restore.
        let base = ExpanderHarness(clipboard: Self.secret)
        let h = EngineHarness(triggers: [itemId: Self.trigger], base: base)
        await h.engine.start()
        defer { h.engine.stop() }

        h.source.type(Self.trigger)
        h.source.press(TriggerKeys.space, " ")
        #expect(await eventually { base.pasteboard.plainText == Self.secret && base.pasteboard.writes.count == 2 })

        #expect(base.pasteboard.snapshotReads == 1)
        #expect(!base.sink.allText.contains(Self.secret))
    }
}
