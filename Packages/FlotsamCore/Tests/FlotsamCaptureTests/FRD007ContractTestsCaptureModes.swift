import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

// FRD-007 8T contract tests, slice S2 (Capture half): what the capture modes do to the clipboard poll and Save
// Clipboard (OC-7103, OC-7104 Save Clipboard half, OC-7105 capture half, OC-7107). Real ClipboardCapture, classifier,
// IngestActor and an on-disk database in a temp folder (ContractRig); only the pasteboard, source-app lookup, clock
// and timer are fakes. Counts are read through a FRESH database instance on the same folder.
//
// The screenshot halves are in FlotsamScreenshotsTests, the Shelf half of OC-7104 in FlotsamShelfTests, the menu and
// persistence halves in FlotsamBaseTests (same file name). The OC-7103 / OC-7104 sentences that span two modules at
// once (clipboard AND screenshot AND Save Clipboard in one run; Shelf drop AND Save Clipboard in one count) have no
// single-target seam (no test target imports Capture with Screenshots or Shelf, ADR-0001), so each half asserts its own
// delta; see FRD007ContractTestsGaps.swift.

@MainActor @Suite("FRD-007 contract: capture modes (Capture)", .serialized, .timeLimit(.minutes(2)))
struct FRD007ContractCaptureModeCaptureTests {
    private func texts(_ rig: ContractRig) async throws -> [String] {
        let fresh = try await FlotsamDatabase.open(folder: rig.folder).get()
        return try await fresh.pool.read { try String.fetchAll($0, sql: "SELECT plainText FROM item ORDER BY plainText") }
    }

    /// OC-7103 (clipboard half). Curated: a copy stores nothing; Save Clipboard then stores exactly that text, once.
    /// Red if Curated starts capturing copies on its own, or Save Clipboard stops working in Curated.
    @Test("OC-7103 Curated: a copy leaves the count at N, Save Clipboard makes it N+1 with that text, no image kind")
    func oc7103_curatedCopyThenSave() async throws {
        try await withRig(scheduleTimer: inertTimer) { rig in
            // given Curated with N = 1 item already saved
            rig.settings.set(CaptureMode.curated, for: SettingKeys.captureMode)
            rig.pasteboard.copyText("MARK-C0")
            _ = await rig.capture.saveClipboardNow()
            try #expect(await rig.freshItemCount() == 1)

            // when MARK-C1 is copied
            rig.pasteboard.copyText("MARK-C1")
            await rig.process()
            // then the count stays N, and MARK-C1 is not stored
            try #expect(await rig.freshItemCount() == 1)
            try #expect(await texts(rig) == ["MARK-C0"])

            // when Save Clipboard runs
            let outcome = await rig.capture.saveClipboardNow()
            // then the count is N+1, the new item's text is MARK-C1, the old one survives, nothing is an image
            if case .saved = outcome {} else { Issue.record("Save Clipboard in Curated did not save: \(outcome)") }
            try #expect(await rig.freshItemCount() == 2)
            try #expect(await texts(rig) == ["MARK-C0", "MARK-C1"])
            try #expect(await rig.kinds().allSatisfy { $0 == "text" })
        }
    }

    /// OC-7104 (Save Clipboard half). In Paused, Save Clipboard still saves: count N+1, the saved item is the copied
    /// text and the mode stays Paused. The Shelf-drop half is in FlotsamShelfTests.
    /// Red if Save Clipboard starts honouring Paused, or running it changes the mode.
    @Test("OC-7104 Paused: Save Clipboard makes the count N+1 with that text and the mode stays Paused")
    func oc7104_pausedSaveClipboardSaves() async throws {
        try await withRig(scheduleTimer: inertTimer) { rig in
            // given Paused with N = 1 saved item
            rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
            rig.pasteboard.copyText("MARK-S0")
            _ = await rig.capture.saveClipboardNow()
            try #expect(await rig.freshItemCount() == 1)

            // when MARK-S1 is copied, then Save Clipboard runs
            rig.pasteboard.copyText("MARK-S1")
            await rig.process()
            try #expect(await rig.freshItemCount() == 1, "the paused poll did not capture the copy")
            let outcome = await rig.capture.saveClipboardNow()

            // then N+1, both texts present, still Paused
            if case .saved = outcome {} else { Issue.record("Save Clipboard in Paused did not save: \(outcome)") }
            try #expect(await rig.freshItemCount() == 2)
            try #expect(await texts(rig) == ["MARK-S0", "MARK-S1"])
            #expect(rig.settings.value(SettingKeys.captureMode) == .paused)
        }
    }

    /// OC-7102 (clipboard half). Paused: a copy creates nothing, and after Resume the copy made during the pause is
    /// still not captured (no backfill, even by the check that runs right after the change). The screenshot half is in
    /// FlotsamScreenshotsTests.
    /// Red if Paused stores the copy, or resume re-baselines the pasteboard too late and takes the paused-period text.
    @Test("OC-7102 Paused then resumed: MARK-P1 copied during the pause is never imported, count stays N")
    func oc7102_pausedCopyNotBackfilledOnResume() async throws {
        try await withRig(scheduleTimer: inertTimer) { rig in
            // given Paused with N = 1 saved item (MARK-N0 captured while Active)
            rig.pasteboard.copyText("MARK-N0")
            await rig.process()
            try #expect(await texts(rig) == ["MARK-N0"])
            rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
            rig.capture.applyMode()
            await rig.flush()

            // when MARK-P1 is copied while paused and polls run, then the user resumes
            rig.pasteboard.copyText("MARK-P1")
            await rig.process()
            try #expect(await rig.freshItemCount() == 1, "stays N while paused")
            rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
            rig.capture.applyMode()
            await rig.flush()
            await rig.process()

            // then still N after resume and MARK-P1 is nowhere in the store
            try #expect(await rig.freshItemCount() == 1)
            try #expect(await texts(rig) == ["MARK-N0"])

            // control: a copy made after resume IS captured, so the zero above is the pause and not a dead rig
            rig.pasteboard.copyText("MARK-P2")
            await rig.process()
            try #expect(await texts(rig) == ["MARK-N0", "MARK-P2"])
        }
    }

    /// OC-7105 (capture half). Flotsam launched with Paused already stored: starting capture does not take what is on
    /// the clipboard, and a copy afterwards creates no item.
    /// Red if the launch check or the poll ignores a persisted Paused.
    @Test("OC-7105 launching while Paused: neither the launch check nor a later copy creates an item")
    func oc7105_launchPausedCapturesNothing() async throws {
        try await withRig(startCapture: false, scheduleTimer: inertTimer) { rig in
            // given Paused stored, text already on the clipboard, and Flotsam launching (capture.start)
            rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
            rig.pasteboard.copyText("MARK-LAUNCH")
            rig.capture.start()
            await rig.flush()
            try #expect(await rig.freshItemCount() == 0)

            // when text is copied after launch
            rig.pasteboard.copyText("MARK-AFTER")
            await rig.process()

            // then still no item, and the mode is still Paused
            try #expect(await rig.freshItemCount() == 0)
            #expect(rig.settings.value(SettingKeys.captureMode) == .paused)

            // control: after Resume the next copy IS captured, so the zero above is the mode and not a dead rig
            rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
            rig.pasteboard.copyText("MARK-RESUMED")
            await rig.process()
            try #expect(await texts(rig) == ["MARK-RESUMED"])
        }
    }

    /// OC-7107. Changing the mode Active, Paused, Curated, Active never discards or rewrites the held clipboard:
    /// after each change the pasteboard still holds MARK-H1 at the same changeCount, and Flotsam wrote nothing.
    /// Red if a mode change clears or rewrites the pasteboard, or discards the stored item for the held text.
    @Test("OC-7107 changing mode keeps MARK-H1 on the pasteboard at the same changeCount with no Flotsam write")
    func oc7107_modeChangesLeavePasteboardAlone() async throws {
        try await withRig(scheduleTimer: inertTimer) { rig in
            // given MARK-H1 on the pasteboard (captured while Active) at changeCount C
            rig.pasteboard.copyText("MARK-H1")
            await rig.process()
            let c = rig.pasteboard.changeCount
            try #expect(await texts(rig) == ["MARK-H1"])

            // when the mode goes Active -> Paused -> Curated -> Active
            for mode in [CaptureMode.paused, .curated, .active] {
                rig.settings.set(mode, for: SettingKeys.captureMode)
                rig.capture.applyMode()
                await rig.flush()

                // then after each change the pasteboard is as it was and Flotsam made no write
                #expect(rig.pasteboard.changeCount == c, "after \(mode)")
                #expect(rig.pasteboard.writes == 0, "after \(mode)")
                #expect(rig.pasteboard.currentTypeIdentifiers() == ["public.utf8-plain-text"], "after \(mode)")
                if case .success(let snapshot) = rig.pasteboard.readSnapshot(types: ["public.utf8-plain-text"]) {
                    #expect(snapshot.representations.map { String(decoding: $0.data, as: UTF8.self) } == ["MARK-H1"], "after \(mode)")
                } else {
                    Issue.record("pasteboard unreadable after \(mode)")
                }
                // and the stored item for it is still there, not duplicated by the resume's immediate check
                try #expect(await rig.freshItemCount() == 1, "after \(mode)")
            }
        }
    }
}
