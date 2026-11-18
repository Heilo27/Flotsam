import Foundation
import Testing
import FlotsamBase
import FlotsamPayload
@testable import FlotsamStorage
@testable import FlotsamCapture

// TASK-442 / FR-001-01, FR-001-18, AC-001-01, AC-001-18: a writer that clears the pasteboard and writes later. The
// clear bumps the changeCount, the write does not, so capture keeps reading the still-empty change on every poll for
// `ClipboardCapture.emptyChangeWatchLimit` (10 s) and stores what arrives. Time is the rig's ManualClock and the board
// is the fake `ContractPasteboard`: nothing here sleeps for the gap.

/// Polls the way the 0.5 s timer does, on the fake clock.
@MainActor
private func poll(_ rig: ContractRig, every step: TimeInterval = 0.5, for duration: TimeInterval) {
    var elapsed = 0.0
    while elapsed < duration {
        rig.clock.advance(by: step)
        rig.capture.captureNow()
        elapsed += step
    }
}

/// A non-atomic copy: `clearContents` now, the content `gap` seconds later with no second bump, a poll every 0.5 s from
/// the clear until `total` seconds have passed. The write lands just before the first poll at or after `gap`.
@MainActor
private func lateWrite(_ rig: ContractRig, text: String, gap: TimeInterval, total: TimeInterval) {
    rig.pasteboard.clear()
    rig.capture.captureNow()  // the first poll sees the cleared board
    var elapsed = 0.0
    var written = false
    while elapsed < total {
        rig.clock.advance(by: 0.5)
        elapsed += 0.5
        if !written, elapsed >= gap { rig.pasteboard.fillText(text); written = true }
        rig.capture.captureNow()
    }
    if !written { rig.pasteboard.fillText(text) }
}

/// A change that stays empty for its whole watch and is polled past its end, so it counts (FR-001-18 b).
@MainActor
private func emptyChangeThatNeverFills(_ rig: ContractRig) {
    rig.pasteboard.clear()
    rig.capture.captureNow()
    poll(rig, for: 10.5)  // the FRD's 10 s, a literal on purpose: the test pins the product number, not the constant
}

/// Waits for `count` items, then lets any further ingest and report settle, so "exactly" holds.
@MainActor
private func settledItems(_ rig: ContractRig, expecting count: Int) async throws -> [StoredItem] {
    _ = await rig.until { try await rig.itemCount() == count }
    await rig.flush()
    return try await rig.items()
}

@MainActor
@Suite("TASK-442: a write that lands after the clear (FR-001-01, FR-001-18)")
struct ClipboardLateWriteTests {

    @Test("AC-001-01 late write: a copy whose content lands 1.5 s, 5 s or 9 s after the clear is stored exactly once", arguments: [1.5, 5.0, 9.0])
    func lateWriteIsStoredOnce(gap: Double) async throws {
        try await withRig { rig in
            let text = uid("late")
            lateWrite(rig, text: text, gap: gap, total: 12)
            let items = try await settledItems(rig, expecting: 1)
            #expect(items.map(\.plainText) == [text])
            #expect(items.map(\.copyCount) == [1])
            // and it never counted as an empty change: no CAP-VAL-001, no suspension
            #expect(rig.sink.logged(.capVal001).isEmpty)
            #expect(rig.sink.logged(.capPrm001).isEmpty)
        }
    }

    @Test("AC-001-01 late write: a 9 s late write does not suspend capture, even among still-empty changes")
    func nineSecondWriteDoesNotCountTowardSuspension() async throws {
        try await withRig { rig in
            // two empty changes, then a change that fills 9 s late, then two more empty changes: were the late change
            // counted that would be five, and even three in a row (the late one and two more) would suspend
            emptyChangeThatNeverFills(rig)
            emptyChangeThatNeverFills(rig)
            lateWrite(rig, text: "late", gap: 9, total: 10)
            emptyChangeThatNeverFills(rig)
            emptyChangeThatNeverFills(rig)
            let items = try await settledItems(rig, expecting: 1)
            #expect(items.map(\.plainText) == ["late"])
            #expect(rig.sink.logged(.capPrm001).isEmpty)
            #expect(rig.presenter.latestNotices.isEmpty)
        }
    }

    @Test("AC-001-01 late write: a write 12 s after the clear is not stored and logs CAP-VAL-001")
    func writeAfterTheWatchIsNotStored() async throws {
        try await withRig { rig in
            lateWrite(rig, text: "too late", gap: 12, total: 14)
            await rig.flush()
            try #expect(await rig.itemCount() == 0)
            #expect(rig.sink.logged(.capVal001).count == 1)
            #expect(rig.sink.logged(.capPrm001).isEmpty)
        }
    }

    @Test("AC-001-18 late write: three copies in a row that each fill 1.5 s late leave capture running, no CAP-PRM-001")
    func threeLateWritesKeepCaptureRunning() async throws {
        try await withRig { rig in
            for n in 1...3 { lateWrite(rig, text: "copy \(n)", gap: 1.5, total: 3) }
            let items = try await settledItems(rig, expecting: 3)
            #expect(items.map(\.plainText) == ["copy 1", "copy 2", "copy 3"])
            #expect(rig.sink.logged(.capPrm001).isEmpty)
            #expect(rig.sink.logged(.capVal001).isEmpty)
            #expect(rig.presenter.latestNotices.isEmpty)
            // and capture is still on: the next copy is stored
            rig.pasteboard.copyText("after")
            rig.capture.captureNow()
            let all = try await settledItems(rig, expecting: 4)
            #expect(all.last?.plainText == "after")
        }
    }

    @Test("AC-001-18 late write: three changes still empty when their 10 s watch ends suspend capture with CAP-PRM-001")
    func threeStillEmptyChangesSuspend() async throws {
        try await withRig { rig in
            emptyChangeThatNeverFills(rig)
            emptyChangeThatNeverFills(rig)
            await rig.flush()
            #expect(rig.sink.logged(.capPrm001).isEmpty, "two are below the threshold")
            #expect(rig.sink.logged(.capVal001).count == 2)
            emptyChangeThatNeverFills(rig)
            _ = await rig.until { !noticeMessages(rig, code: .capPrm001).isEmpty }
            #expect(rig.sink.logged(.capPrm001).count == 1)
            #expect(noticeMessages(rig, code: .capPrm001).count == 1)
        }
    }

    @Test("AC-001-01 late write: a newer changeCount during the watch ends it; the new change is stored exactly once")
    func newerChangeEndsTheWatch() async throws {
        try await withRig { rig in
            rig.pasteboard.clear()
            rig.capture.captureNow()
            poll(rig, for: 2)
            // when another copy bumps the count while the first change is still empty
            rig.pasteboard.copyText("second")
            rig.capture.captureNow()
            poll(rig, for: 12)
            // then the second is stored once, and the first (empty when its watch ended) counted as one empty change
            let items = try await settledItems(rig, expecting: 1)
            #expect(items.map(\.plainText) == ["second"])
            #expect(items.map(\.copyCount) == [1])
            #expect(rig.sink.logged(.capVal001).count == 1)
            #expect(rig.sink.logged(.capPrm001).isEmpty)
        }
    }

    @Test("AC-001-01 late write boundary: content at 9.9 s is stored")
    func contentJustInsideTheWatchIsStored() async throws {
        try await withRig { rig in
            rig.pasteboard.clear()
            rig.capture.captureNow()
            rig.clock.advance(by: 9.9)
            rig.pasteboard.fillText("inside")
            rig.capture.captureNow()
            let items = try await settledItems(rig, expecting: 1)
            #expect(items.map(\.plainText) == ["inside"])
            #expect(rig.sink.logged(.capVal001).isEmpty)
        }
    }

    @Test("AC-001-01 late write boundary: content at 10.0 s is not stored; the change counts as empty and logs CAP-VAL-001")
    func contentAtTheLimitIsNotStored() async throws {
        try await withRig { rig in
            rig.pasteboard.clear()
            rig.capture.captureNow()
            rig.clock.advance(by: 10.0)  // literal on purpose: pins the FRD's 10 s
            rig.pasteboard.fillText("at the limit")
            rig.capture.captureNow()
            rig.capture.captureNow()  // the watch is over: later polls do not read it either
            await rig.flush()
            try #expect(await rig.itemCount() == 0)
            #expect(rig.sink.logged(.capVal001).count == 1)
        }
    }
}
