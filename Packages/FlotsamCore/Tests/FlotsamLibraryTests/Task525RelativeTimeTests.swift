import FlotsamBase
import FlotsamStorage
import Foundation
import Observation
import Testing
@testable import FlotsamLibrary

/// TASK-525 (FR-003-07, FR-003-21): a Library row's relative time and its VoiceOver label advance while the panel stays
/// open, from one clock, and nothing ticks while the panel is hidden. Reported from a real-OS run: "2 min ago" did not
/// move while the panel stayed open.

/// A clock whose `sleep` parks until the test releases it, advancing time by the requested duration, and records each
/// request. Nothing sleeps for real.
final class GatedClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var requested: [TimeInterval] = []
    private var waiters: [(seconds: TimeInterval, resume: CheckedContinuation<Void, Never>)] = []

    init(_ start: Date) { current = start }

    func now() -> Date { lock.withLock { current } }
    var sleeps: [TimeInterval] { lock.withLock { requested } }
    var parked: Int { lock.withLock { waiters.count } }

    func sleep(for duration: Duration) async {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    requested.append(seconds)
                    waiters.append((seconds, continuation))
                }
            }
        } onCancel: {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { waiters = [] }
                return waiters.map(\.resume)
            }
            all.forEach { $0.resume() }
        }
    }

    /// Lets the parked sleeper wake, with time moved on by what it asked for.
    func release() {
        let waiter = lock.withLock { () -> (seconds: TimeInterval, resume: CheckedContinuation<Void, Never>)? in
            guard !waiters.isEmpty else { return nil }
            let first = waiters.removeFirst()
            current = current.addingTimeInterval(first.seconds)
            return first
        }
        waiter?.resume.resume()
    }

    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

@MainActor
@Suite struct Task525RelativeTimeTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(ages: [TimeInterval], clock: GatedClock? = nil) -> (model: LibraryViewModel, clock: GatedClock) {
        let clock = clock ?? GatedClock(Self.start)
        let rows = ages.enumerated().map { makeRow($0.offset, copiedAt: Self.start.addingTimeInterval(-$0.element)) }
        let model = LibraryViewModel(
            source: FakeSource(rows: rows, counts: nil), paster: FakePaster(), host: FakeHost(),
            preferences: FakePreferences(), clock: clock)
        return (model, clock)
    }

    /// Hang guard only: the condition is an event, not a bound.
    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return condition()
    }

    private func returns(_ task: Task<Void, Never>) async -> Bool {
        let timedOut = Flag()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            timedOut.raise()
            task.cancel()
        }
        await task.value
        watchdog.cancel()
        return !timedOut.isRaised
    }

    // MARK: The reported behaviour

    @Test func visibleLabelAndSpokenLabelBothAdvanceWhileThePanelStaysOpen() async {
        let (model, clock) = make(ages: [120])
        await model.open(target: nil)
        let before = model.rowPresentations()[0]
        #expect(before.secondaryText == "Notes · 2m ago")
        #expect(before.accessibilityLabel.contains("2m ago"))

        let changed = Flag()
        withObservationTracking({ _ = model.rowPresentations() }, onChange: { changed.raise() })
        let watch = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        #expect(!changed.isRaised, "nothing re-renders before the label is due")

        clock.release()
        #expect(await waitFor { changed.isRaised }, "the rows' subscribers are told when the label is due")
        let after = model.rowPresentations()[0]
        #expect(after.secondaryText == "Notes · 3m ago")
        #expect(after.accessibilityLabel.contains("3m ago"))
        #expect(!after.accessibilityLabel.contains("2m ago"))
        watch.cancel()
        _ = await returns(watch)
    }

    @Test func theVisibleAndSpokenLabelsAlwaysComeFromTheSameInstant() async {
        let (model, clock) = make(ages: [59.99])
        await model.open(target: nil)
        // Whatever the clock says, one pass reads it once: both strings name the same age.
        for _ in 0..<5 {
            let row = model.rowPresentations()[0]
            let visible = row.secondaryText.replacingOccurrences(of: "Notes · ", with: "")
            #expect(row.accessibilityLabel.contains(visible))
            clock.advance(by: 0.5)
        }
    }

    // MARK: Hidden costs nothing

    @Test func aHiddenPanelNeverSchedulesAWakeup() async {
        let (model, clock) = make(ages: [10])
        #expect(await returns(Task { await model.watchRelativeTimes() }), "never shown: returns at once")
        #expect(clock.sleeps.isEmpty)

        await model.open(target: nil)
        model.panelDidHide()
        #expect(!model.loadedRows.isEmpty, "rows stay loaded after a hide, so only isShown can stop the watch")
        #expect(await returns(Task { await model.watchRelativeTimes() }), "hidden with rows loaded: returns at once")
        #expect(clock.sleeps.isEmpty)

        await model.open(target: nil)
        let watch = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        model.panelDidHide()
        clock.release()
        #expect(await returns(watch), "hiding ends the watch at its next wake")
        #expect(clock.sleeps.count == 1, "and it does not sleep again")
        #expect(model.timeRevision == 0, "a hidden panel is not re-rendered")
    }

    @Test func theWatchKeyChangesOnShowHideAndRowChanges() async {
        let (model, _) = make(ages: [10, 20])
        let hidden = model.relativeTimeWatchKey
        await model.open(target: nil)
        let shown = model.relativeTimeWatchKey
        #expect(shown != hidden)
        await model.refresh()
        #expect(model.relativeTimeWatchKey != shown, "a reload restarts the watch so new rows are timed")
        let reloaded = model.relativeTimeWatchKey
        model.panelDidHide()
        #expect(model.relativeTimeWatchKey != reloaded)
    }

    // MARK: Cadence follows the label's granularity

    @Test func theSleepMatchesTheSoonestVisibleLabelsStep() async {
        let slack = LibraryViewModel.relativeTimeSlack
        let cases: [(ages: [TimeInterval], expect: TimeInterval)] = [
            ([30], 1),  // seconds under a minute
            ([330], 30),  // 5m30s: the next minute is 30 s away
            ([3 * 3_600 + 1_800], 1_800),  // 3h30m: the next hour
            ([2 * 86_400 + 43_200], 43_200),  // 2.5 days: the next day
            ([3 * 86_400 + 43_200, 330], 30),  // the youngest row decides
        ]
        for (ages, expect) in cases {
            let (model, clock) = make(ages: ages)
            await model.open(target: nil)
            let watch = Task { await model.watchRelativeTimes() }
            #expect(await waitFor { clock.parked == 1 })
            #expect(abs((clock.sleeps.first ?? -1) - (expect + slack)) < 0.001, "ages \(ages)")
            watch.cancel()
            _ = await returns(watch)
        }
    }

    @Test func rowsThatAreAllDatedNeverWakeThePanel() async {
        let (model, clock) = make(ages: [8 * 86_400, 40 * 86_400])
        await model.open(target: nil)
        #expect(await returns(Task { await model.watchRelativeTimes() }), "nothing left to age: the watch ends")
        #expect(clock.sleeps.isEmpty)
    }

    @Test func aRowThatBecomesDatedStopsTheWatch() async {
        // 6 days 23 h 59 m 30 s old: one wake carries it past 7 days, then nothing can change again.
        let (model, clock) = make(ages: [7 * 86_400 - 30])
        await model.open(target: nil)
        let watch = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        clock.release()
        #expect(await returns(watch), "after the one wake the row is dated and the watch ends")
        #expect(clock.sleeps.count == 1)
        let text = model.rowPresentations()[0].secondaryText
        #expect(!text.contains("ago"), "past 7 days the label is a date: \(text)")
    }

    // MARK: The label rule (ItemSpeech)

    @Test func theRuleFindsTheInstantTheLabelChanges() {
        let now = Self.start
        let ages: [TimeInterval] = [0, 0.4, 1, 29.5, 59.9, 60, 61, 119.9, 120, 3_599, 3_600, 5_000, 86_399, 86_400, 100_000, 172_800, 6 * 86_400 + 100]
        for age in ages {
            let date = now.addingTimeInterval(-age)
            guard let delay = ItemSpeech.secondsUntilRelativeTimeChanges(date, now: now) else {
                Issue.record("age \(age) has a rule")
                continue
            }
            let here = ItemSpeech.relativeTime(date, now: now)
            let justBefore = ItemSpeech.relativeTime(date, now: now.addingTimeInterval(delay - 0.01))
            let justAfter = ItemSpeech.relativeTime(date, now: now.addingTimeInterval(delay + 0.01))
            #expect(justBefore == here, "age \(age): the label holds until the due time (\(here) vs \(justBefore))")
            #expect(justAfter != here, "age \(age): the label has changed after the due time (\(here) vs \(justAfter))")
        }
    }

    @Test func aDatedCopyHasNoNextChange() {
        let now = Self.start
        #expect(ItemSpeech.secondsUntilRelativeTimeChanges(now.addingTimeInterval(-7 * 86_400 - 1), now: now) == nil)
        #expect(ItemSpeech.secondsUntilRelativeTimeChanges(now.addingTimeInterval(-30 * 86_400), now: now) == nil)
    }

    @Test func aCopyTimeInTheFutureReadsAsNowAndAgesFromNow() {
        let now = Self.start
        let delay = ItemSpeech.secondsUntilRelativeTimeChanges(now.addingTimeInterval(500), now: now)
        #expect(delay == 1)
    }
}
