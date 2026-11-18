import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamStorage
@testable import FlotsamCapture

// Worf-442 / FR-001-01, FR-001-18, AC-001-20 .. AC-001-24: the cases the builder's ClipboardLateWriteTests leave open.
// Every number below is a LITERAL from the FRD on purpose (10 s, 9.9 s, 9.5 s): none of these tests reads
// `ClipboardCapture.emptyChangeWatchLimit`, so a changed constant turns them red instead of moving with it.

@MainActor
private func tick(_ rig: ContractRig, after step: TimeInterval = 0.5) {
    rig.clock.advance(by: step)
    rig.capture.captureNow()
}

@MainActor
private func tickFor(_ rig: ContractRig, _ duration: TimeInterval) {
    var elapsed = 0.0
    while elapsed < duration { tick(rig); elapsed += 0.5 }
}

/// A change that stays empty past its 10 s watch (counts as one empty change, FR-001-18 b).
@MainActor
private func staysEmpty(_ rig: ContractRig) {
    rig.pasteboard.clear()
    rig.capture.captureNow()
    tickFor(rig, 10.5)
}

@MainActor
private func settled(_ rig: ContractRig, expecting count: Int) async throws -> [StoredItem] {
    _ = await rig.until { try await rig.itemCount() == count }
    await rig.flush()
    return try await rig.items()
}

@MainActor
@Suite("Worf-442: late-write watch boundaries and supersession (FR-001-01, FR-001-18)")
struct ClipboardLateWriteWorf442Tests {

    // OC-442-01: kills a limit of 9.5 s (or anything below 9.9 s): polled every 0.5 s through 9.5 s, content lands 9.9 s in.
    @Test("OC-442-01 AC-001-24 low side: polled every 0.5 s while empty, content landing at 9.9 s is stored once")
    func polledWatchStillStoresAt9_9() async throws {
        try await withRig { rig in
            // given a cleared board polled every 0.5 s up to 9.5 s, each read empty
            rig.pasteboard.clear()
            rig.capture.captureNow()
            tickFor(rig, 9.5)
            // when the content lands and the next poll is at 9.9 s
            rig.pasteboard.fillText("inside")
            tick(rig, after: 0.4)
            // then it is stored once and nothing counted as empty
            let items = try await settled(rig, expecting: 1)
            #expect(items.map(\.plainText) == ["inside"])
            #expect(items.map(\.copyCount) == [1])
            #expect(rig.sink.logged(.capVal001).isEmpty)
        }
    }

    // OC-442-02: kills a limit of 9.5 s via the 0.5 s tick grid: a write landing just before the 9.5 s poll.
    @Test("OC-442-02 AC-001-20 low side: content landing before the 9.5 s poll is stored once, not counted empty")
    func writeBeforeThe9_5sPollIsStored() async throws {
        try await withRig { rig in
            rig.pasteboard.clear()
            rig.capture.captureNow()
            tickFor(rig, 9.0)
            rig.pasteboard.fillText("nine and a half")
            tick(rig)  // the poll at 9.5 s
            tickFor(rig, 3)
            let items = try await settled(rig, expecting: 1)
            #expect(items.map(\.plainText) == ["nine and a half"])
            #expect(rig.sink.logged(.capVal001).isEmpty)
        }
    }

    // OC-442-03: kills a limit above 10 s (10.5 s, 11 s) and `>=` turned into `>`: a poll at exactly 10.0 s must not read.
    @Test("OC-442-03 AC-001-24 high side: polled every 0.5 s, content landing at 10.0 s is not stored; one CAP-VAL-001")
    func polledWatchEndsAt10() async throws {
        try await withRig { rig in
            rig.pasteboard.clear()
            rig.capture.captureNow()
            tickFor(rig, 9.5)
            rig.pasteboard.fillText("too late")
            tick(rig)  // the poll at 10.0 s: the watch is over, no read
            tickFor(rig, 2)
            await rig.flush()
            try #expect(await rig.itemCount() == 0)
            #expect(rig.sink.logged(.capVal001).count == 1)
        }
    }

    // OC-442-04: kills "a newer changeCount does not count the superseded empty change": the third empty, ended by a
    // newer (also empty) change after 2 s, suspends at once instead of 10 s later.
    @Test("OC-442-04 AC-001-22 supersession: a third empty change superseded by a newer one at 2 s suspends capture then")
    func thirdEmptyEndedByNewerChangeSuspends() async throws {
        try await withRig { rig in
            staysEmpty(rig)
            staysEmpty(rig)
            rig.pasteboard.clear()
            rig.capture.captureNow()
            tickFor(rig, 2)
            await rig.flush()
            #expect(rig.sink.logged(.capPrm001).isEmpty, "the third is still inside its watch")
            // when a newer change arrives that is empty too
            rig.pasteboard.clear()
            rig.capture.captureNow()
            _ = await rig.until { !noticeMessages(rig, code: .capPrm001).isEmpty }
            // then the third was counted at that moment: one suspension, 8 s before its own 10 s would have ended
            #expect(rig.sink.logged(.capPrm001).count == 1)
            #expect(noticeMessages(rig, code: .capPrm001).count == 1)
        }
    }

    // OC-442-05: a readable newer change supersedes a third empty one; capture carries on and the new copy is stored once.
    @Test("OC-442-05 AC-001-23 supersession: a readable copy ending a third empty change is stored once and leaves no CAP-PRM-001 notice")
    func readableChangeEndsThirdEmptyWatch() async throws {
        try await withRig { rig in
            staysEmpty(rig)
            staysEmpty(rig)
            rig.pasteboard.clear()
            rig.capture.captureNow()
            tickFor(rig, 2)
            rig.pasteboard.copyText("rescue")
            rig.capture.captureNow()
            tickFor(rig, 11)
            let items = try await settled(rig, expecting: 1)
            #expect(items.map(\.plainText) == ["rescue"])
            #expect(items.map(\.copyCount) == [1])
            #expect(rig.presenter.latestNotices.isEmpty, "the readable copy resumed capture and cleared the warning")
            // and capture is running: the next copy is stored too
            rig.pasteboard.copyText("after")
            rig.capture.captureNow()
            let all = try await settled(rig, expecting: 2)
            #expect(Set(all.compactMap(\.plainText)) == ["after", "rescue"])
        }
    }

    // OC-442-06: boundary of the suspension count: two empty changes then a late fill then one empty is not three in a row.
    @Test("OC-442-06 AC-001-22 reset: two empties, a copy filling 1.5 s late, then one empty do not suspend")
    func lateFillResetsTheEmptyCount() async throws {
        try await withRig { rig in
            staysEmpty(rig)
            staysEmpty(rig)
            rig.pasteboard.clear()
            rig.capture.captureNow()
            tickFor(rig, 1.5)
            rig.pasteboard.fillText("late")
            tickFor(rig, 1)
            staysEmpty(rig)
            let items = try await settled(rig, expecting: 1)
            #expect(items.map(\.plainText) == ["late"])
            #expect(rig.sink.logged(.capPrm001).isEmpty)
            #expect(rig.sink.logged(.capVal001).count == 3, "three counted empties, none of them the late copy")
        }
    }

    // OC-442-07: Paused stops the poll (no captureNow runs while paused), so only Resume can end the open watch.
    @Test("OC-442-07 FR-001-19: a watch open when capture is Paused does not capture what lands during the pause, after Resume")
    func pauseEndsTheWatch() async throws {
        try await withRig { rig in
            // given a cleared board whose watch is open
            rig.pasteboard.clear()
            rig.capture.captureNow()
            tickFor(rig, 1)
            // when capture is Paused, the content lands during the pause (no poll runs), then capture resumes
            rig.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
            rig.clock.advance(by: 3)
            rig.pasteboard.fillText("while paused")
            rig.settings.set(CaptureMode.active, for: SettingKeys.captureMode)
            tickFor(rig, 11)
            // then it is never captured
            await rig.flush()
            try #expect(await rig.itemCount() == 0)
            #expect(rig.sink.logged(.capPrm001).isEmpty)
        }
    }

    // OC-442-08: Curated (not saving) skips a change with CAP-POL-003, which must end the watch: one skip, not one per tick.
    @Test("OC-442-08 FR-001-19: a watch open when capture goes Curated logs CAP-POL-003 once, not on every tick")
    func curatedEndsTheWatch() async throws {
        try await withRig { rig in
            rig.pasteboard.clear()
            rig.capture.captureNow()
            tickFor(rig, 1)
            let before = rig.sink.logged(.capPol003).count
            rig.settings.set(CaptureMode.curated, for: SettingKeys.captureMode)
            tickFor(rig, 3)  // six ticks
            #expect(rig.sink.logged(.capPol003).count - before == 1)
            try #expect(await rig.itemCount() == 0)
        }
    }
}
