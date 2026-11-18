import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

/// TASK-382 adversarial QA (FR-001-19, AC-001-19, ADR-0004) for `ClipboardCapture`: what a copy does at the pause and
/// resume boundaries, rapid toggling through the real settings subscription, and Curated (unchanged by this task).
/// `applyMode()` and `timerFired()` are the seams the settings subscription and the timer call. `rig.itemsChangedCount`
/// counts committed ingests, so a copy captured twice shows as 2 even when the second is deduplicated into one row.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct Task382AdversarialTests {
    private func set(_ mode: CaptureMode, _ rig: GapRig) {
        rig.settings.set(mode, for: SettingKeys.captureMode)
    }

    private func apply(_ mode: CaptureMode, _ rig: GapRig) {
        set(mode, rig)
        rig.capture.applyMode()
    }

    /// Drains the consumer so `itemsChangedCount` is final.
    private func ingests(_ rig: GapRig) async -> Int {
        await rig.capture.stop()
        return rig.itemsChangedCount.value
    }

    // MARK: Copy at the resume boundary

    /// given a copy made after the resume completed, when the timer fires and `captureNow` runs again, then it is
    /// captured exactly once (one ingest event, one row).
    /// Red if: resume leaves the baseline stale so the same change is read by both the immediate check and the poll.
    @Test func copyAfterResumeIsCapturedExactlyOnce() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        apply(.paused, rig)
        apply(.active, rig)
        rig.text("after resume")
        rig.capture.timerFired()
        rig.capture.captureNow()
        rig.capture.timerFired()
        #expect(await ingests(rig) == 1)
        #expect(try await rig.freshRows().map(\.plainText) == ["after resume"])
    }

    /// given a copy landing in the window between the mode flipping to Active and `applyMode()` running (the settings
    /// subscription hops to the main actor), when `applyMode` then runs and the timer fires, then it is captured once
    /// or not at all, never twice.
    /// Red if: the re-baseline and the poll can both ingest the same change.
    @Test func copyInsideTheResumeHopIsNeverCapturedTwice() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        apply(.paused, rig)
        set(.active, rig)
        rig.text("on the boundary")
        rig.capture.applyMode()
        for _ in 0..<3 { rig.capture.timerFired() }
        let count = await ingests(rig)
        #expect(count <= 1, "ingest events: \(count)")
    }

    /// given a copy made after the flip to Active but before `applyMode()`, with `captureNow` called in that window
    /// (an activation or Library show), when `applyMode` runs and ticks follow, then that copy is ingested exactly once.
    /// Red if: `applyMode`'s immediate check re-ingests the change `captureNow` already handled.
    @Test func captureNowInsideTheResumeHopThenApplyModeIngestsOnce() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        apply(.paused, rig)
        set(.active, rig)
        rig.text("post-flip copy")
        rig.capture.captureNow()
        rig.capture.applyMode()
        for _ in 0..<3 { rig.capture.timerFired() }
        #expect(await ingests(rig) == 1)
    }

    /// given a copy made while Paused (never polled), when the user resumes and `captureNow` runs in the window
    /// between the setting flipping and `applyMode()` (an activation, the Library showing), then the Paused-era copy is
    /// NOT captured (FR-001-19: nothing copied while Paused is ever captured).
    /// Red when: `captureNow` in the hop reads the stale baseline and ingests. FAILS on 14c52e4 (see W382-D3).
    @Test(.disabled("DEFECT W382-D3 ClipboardCapture.swift:124-135 / :176 / :203: captureNow between the mode flipping to Active and applyMode running reads the stale baseline and ingests a Paused-era copy")) func pausedEraCopyIsNotCapturedByACaptureNowInsideTheResumeHop() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        apply(.paused, rig)
        rig.text("copied while paused")
        set(.active, rig)
        rig.capture.captureNow()
        rig.capture.applyMode()
        for _ in 0..<3 { rig.capture.timerFired() }
        #expect(await ingests(rig) == 0)
        #expect(try await rig.freshRows().isEmpty)
    }

    /// given a Paused-era copy and `captureNow` called while still Paused (Library opened), when the user then resumes
    /// through the hop, then nothing is captured and the pause-time `captureNow` itself captured nothing either.
    /// Red if: `captureNow` ever ingests while the mode is Paused.
    @Test func captureNowWhilePausedNeverIngests() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        apply(.paused, rig)
        rig.text("copied while paused")
        rig.capture.captureNow()
        rig.capture.captureNow()
        #expect(rig.itemsChangedCount.value == 0)
        set(.active, rig)
        rig.capture.captureNow()
        rig.capture.applyMode()
        for _ in 0..<3 { rig.capture.timerFired() }
        #expect(await ingests(rig) == 0)
    }

    // MARK: Rapid pause / resume / pause

    /// given pause, resume, pause in a row with a copy during each Paused stretch, when the last resume is followed by a
    /// fresh copy, then only the fresh copy is captured, once.
    /// Red if: any re-baseline is skipped on a quick toggle, or a later resume captures an earlier Paused copy.
    @Test func rapidTogglesNeverLeakPausedCopies() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        apply(.paused, rig)
        rig.text("paused copy 1")
        apply(.active, rig)
        apply(.paused, rig)
        rig.text("paused copy 2")
        rig.capture.timerFired()
        apply(.active, rig)
        for _ in 0..<3 { rig.capture.timerFired() }
        #expect(rig.itemsChangedCount.value == 0)
        rig.text("fresh copy")
        rig.capture.timerFired()
        #expect(await ingests(rig) == 1)
        #expect(try await rig.freshRows().map(\.plainText) == ["fresh copy"])
    }

    /// given pause, resume, pause with a consumer registered, then the timer is the 5 s one, there is exactly one timer
    /// (a single scheduled interval), and ticks read the pasteboard zero times.
    /// Red if: a rapid toggle leaves the 0.5 s timer alive or the poll running.
    @Test func rapidPauseResumePauseLeavesOneSlowTimerAndNoPolling() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        _ = tick.every(5) {}
        rig.capture.start()
        apply(.paused, rig)
        apply(.active, rig)
        apply(.paused, rig)
        #expect(tick.cadence == 5)
        #expect(rig.capture.scheduledTimerInterval == 5)
        let reads = rig.pasteboard.changeCountReads
        for _ in 0..<10 { rig.capture.timerFired() }
        #expect(rig.pasteboard.changeCountReads == reads)
    }

    /// given three settings writes in a row (Paused, Active, Paused) before the main actor runs any subscription hop,
    /// when the hops run, then capture settles Paused with the 5 s timer (the real settings-driven path, no direct
    /// `applyMode`).
    /// Red if: the subscription path latches an intermediate value instead of reading the current mode.
    @Test func settingsDrivenPauseActivePauseSettlesPaused() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        _ = tick.every(5) {}
        rig.capture.start()
        set(.paused, rig)
        set(.active, rig)
        set(.paused, rig)
        let settled = await eventually { rig.capture.scheduledTimerInterval == 5 }
        #expect(settled, "timer: \(String(describing: rig.capture.scheduledTimerInterval))")
        #expect(tick.cadence == 5)
    }

    /// given Paused then Active in the same synchronous block (net Active), when the hops run, then capture is Active
    /// at 0.5 s and a later copy is captured once.
    /// Red if: the subscription latches Paused from the first write.
    @Test func settingsDrivenPauseThenActiveEndsActive() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        _ = tick.every(5) {}
        rig.capture.start()
        set(.paused, rig)
        set(.active, rig)
        try await Task.sleep(for: .milliseconds(100))
        #expect(tick.cadence == 0.5)
        #expect(rig.capture.scheduledTimerInterval == 0.5)
        rig.text("later")
        rig.capture.timerFired()
        #expect(await ingests(rig) == 1)
    }

    // MARK: Pause racing a tick

    /// given a PollTick consumer that pauses capture from inside `timerFired()` (the pause lands mid-tick), when the
    /// timer fires, then there is no deadlock, the timer is the slow one, and later ticks do not poll.
    /// Red if: `timerFired` holds a lock or state across `pollTick.fire()` such that a mode change inside it is lost.
    @Test func pauseLandingInsideATickTakesEffect() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        nonisolated(unsafe) let target = rig
        // Runs on the 0.5 s tick, on the main actor, from `fire()` (the documented contract).
        _ = tick.every(0.5) {
            MainActor.assumeIsolated {
                target.settings.set(CaptureMode.paused, for: SettingKeys.captureMode)
                target.capture.applyMode()
            }
        }
        rig.capture.start()
        #expect(tick.cadence == 0.5)
        rig.capture.timerFired()
        #expect(rig.capture.scheduledTimerInterval == 0.5, "the 0.5 s consumer still needs the fast tick")
        let reads = rig.pasteboard.changeCountReads
        rig.capture.timerFired()
        #expect(rig.pasteboard.changeCountReads == reads, "paused: the poll no longer reads")
    }

    /// given a copy made just before the pause with the tick not yet run, when the stale timer fires after the pause,
    /// then it is not captured by that firing (Paused skips the poll) and not after resume (re-baseline).
    /// Red if: a stale firing after the pause polls once more.
    @Test func staleFiringAfterPauseDoesNotPoll() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        rig.text("copied then paused within one tick")
        apply(.paused, rig)
        rig.capture.timerFired()
        apply(.active, rig)
        for _ in 0..<3 { rig.capture.timerFired() }
        #expect(await ingests(rig) == 0)
    }

    // MARK: Consumers and the timer

    /// given Paused with consumers, when the last consumer cancels, then no timer is scheduled; when one registers
    /// again the timer returns at its cadence; resume returns 0.5 s.
    /// Red if: cancelling the last consumer leaves a stale timer, or re-registering does not re-arm it.
    @Test func lastConsumerCancelledWhilePausedRemovesTheTimer() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        let cancel = tick.every(5) {}
        rig.capture.start()
        apply(.paused, rig)
        #expect(rig.capture.scheduledTimerInterval == 5)
        cancel()
        let gone = await eventually { rig.capture.scheduledTimerInterval == nil }
        #expect(gone)
        let again = tick.every(30) {}
        let back = await eventually { rig.capture.scheduledTimerInterval == 30 }
        #expect(back)
        apply(.active, rig)
        #expect(rig.capture.scheduledTimerInterval == 0.5)
        again()
        #expect(tick.registrationCount == 0)
        #expect(rig.capture.scheduledTimerInterval == 0.5)
    }

    /// given a stopped capture, when consumers register and cancel (the observer hops to the main actor), then no
    /// timer is ever (re)created.
    /// Red if: the observer reschedules after `stop()`.
    @Test func noTimerResurrectsAfterStop() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        rig.capture.start()
        await rig.capture.stop()
        #expect(rig.capture.scheduledTimerInterval == nil)
        let cancel = tick.every(5) {}
        tick.setFastTickNeeded(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.capture.scheduledTimerInterval == nil)
        cancel()
    }

    /// given `applyMode()` called before `start()`, when later started, then it is a no-op (no timer) and start picks
    /// the mode up (Paused -> 5 s with a consumer).
    /// Red if: `applyMode` acts on a capture that has not started.
    @Test func applyModeBeforeStartIsIgnored() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        _ = tick.every(5) {}
        apply(.paused, rig)
        #expect(rig.capture.scheduledTimerInterval == nil)
        rig.capture.start()
        #expect(rig.capture.scheduledTimerInterval == 5)
    }

    // MARK: Curated (unchanged by this task)

    /// given Curated, then capture still polls at 0.5 s (the poll is not stopped; only Paused stops it), the pasteboard
    /// is read every tick, and nothing is captured automatically (gate 1 still rejects).
    /// Red if: Curated is treated like Paused (cadence slows or the poll stops) or starts capturing.
    @Test func curatedStillPollsAtHalfASecondAndCapturesNothing() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        _ = tick.every(5) {}
        rig.capture.start()
        apply(.curated, rig)
        #expect(tick.cadence == 0.5)
        #expect(rig.capture.scheduledTimerInterval == 0.5)
        let reads = rig.pasteboard.changeCountReads
        rig.text("curated copy")
        for _ in 0..<4 { rig.capture.timerFired() }
        #expect(rig.pasteboard.changeCountReads == reads + 4)
        #expect(await ingests(rig) == 0)
    }

    /// given Active -> Paused -> Curated -> Active, then the cadence is 0.5, 5, 0.5, 0.5, and a copy made while Paused
    /// is never captured even though Curated (which polls) intervened.
    /// Red if: leaving Paused for Curated skips the re-baseline or the cadence restore.
    @Test func pausedToCuratedRestoresTheTickAndStillDropsThePausedCopy() async throws {
        let tick = PollTick()
        let rig = try await GapRig(pollTick: tick)
        defer { Task { await rig.cleanUp() } }
        _ = tick.every(5) {}
        rig.capture.start()
        var seen: [Double?] = [tick.cadence]
        apply(.paused, rig); seen.append(tick.cadence)
        rig.text("copied while paused")
        apply(.curated, rig); seen.append(tick.cadence)
        apply(.active, rig); seen.append(tick.cadence)
        #expect(seen == [0.5, 5, 0.5, 0.5])
        for _ in 0..<3 { rig.capture.timerFired() }
        #expect(await ingests(rig) == 0)
    }
}
