import FlotsamBase
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

/// TASK-525 adversarial round (Worf): the step-table boundaries walked wake by wake, cancellation, the first sleep after
/// a hide and re-show, clock jumps, the empty list, and the one-clock-read-per-pass rule. Every expected value is a
/// literal; none is derived from `ItemSpeech` or the view model.

/// A clock that advances `step` seconds on every `now()` call, so a second read within one pass is visible.
private final class TickingClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var count = 0
    private let step: TimeInterval
    init(_ start: Date, step: TimeInterval) { current = start; self.step = step }
    func now() -> Date {
        lock.withLock {
            defer { current = current.addingTimeInterval(step); count += 1 }
            return current
        }
    }
    var reads: Int { lock.withLock { count } }
    func sleep(for duration: Duration) async {}
}

@MainActor
@Suite struct Task525AdversarialTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(
        ages: [TimeInterval], clock: (any WallClock)? = nil
    ) -> (model: LibraryViewModel, clock: GatedClock) {
        let gated = (clock as? GatedClock) ?? GatedClock(Self.start)
        let rows = ages.enumerated().map { makeRow($0.offset, copiedAt: Self.start.addingTimeInterval(-$0.element)) }
        let model = LibraryViewModel(
            source: FakeSource(rows: rows, counts: nil), paster: FakePaster(), host: FakeHost(),
            preferences: FakePreferences(), clock: clock ?? gated)
        return (model, gated)
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return condition()
    }

    /// True when `task` ends within 10 s on its own. Polls a flag rather than awaiting the task, so a task that never
    /// ends (a cancel that was not forwarded) fails this check instead of hanging the whole run; it is then cancelled.
    private func returns(_ task: Task<Void, Never>) async -> Bool {
        let finished = Flag()
        let observer = Task { await task.value; finished.raise() }
        let ended = await waitForFlag(finished, seconds: 10)
        if !ended { task.cancel() }
        observer.cancel()
        return ended
    }

    private func waitForFlag(_ flag: Flag, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !flag.isRaised, Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return flag.isRaised
    }

    /// Lets the watch wake `times` times, collecting the first row's visible text after each wake.
    private func walk(_ model: LibraryViewModel, _ clock: GatedClock, wakes times: Int) async -> [String] {
        let watch = Task { await model.watchRelativeTimes() }
        var seen: [String] = []
        for wake in 1...times {
            guard await waitFor({ clock.parked == 1 }) else { break }
            clock.release()
            guard await waitFor({ model.timeRevision == wake }) else { break }
            seen.append(model.rowPresentations()[0].secondaryText)
        }
        watch.cancel()
        _ = await returns(watch)
        return seen
    }

    // MARK: Boundaries, wake by wake

    @Test func theLabelReadsNewAfterEveryWakeAcrossTheSecondToMinuteBoundary() async {
        let (model, clock) = make(ages: [58.2])
        await model.open(target: nil)
        #expect(model.rowPresentations()[0].secondaryText == "Notes · 58s ago")
        #expect(await walk(model, clock, wakes: 3) == ["Notes · 59s ago", "Notes · 1m ago", "Notes · 2m ago"])
    }

    @Test func theLabelReadsNewAfterEveryWakeAcrossTheMinuteToHourBoundary() async {
        let (model, clock) = make(ages: [3_599.5])
        await model.open(target: nil)
        #expect(model.rowPresentations()[0].secondaryText == "Notes · 59m ago")
        #expect(await walk(model, clock, wakes: 2) == ["Notes · 1h ago", "Notes · 2h ago"])
    }

    @Test func theLabelReadsNewAfterEveryWakeAcrossTheHourToDayBoundary() async {
        let (model, clock) = make(ages: [86_399.5])
        await model.open(target: nil)
        #expect(model.rowPresentations()[0].secondaryText == "Notes · 23h ago")
        #expect(await walk(model, clock, wakes: 2) == ["Notes · Yesterday", "Notes · 2d ago"])
    }

    @Test func aRowJustUnderSevenDaysTurnsIntoADateAtTheNextWakeAndTheWatchEnds() async {
        let (model, clock) = make(ages: [7 * 86_400 - 0.5])
        await model.open(target: nil)
        let before = model.rowPresentations()[0].secondaryText
        #expect(before.contains("ago") || before.contains("wk"), "still relative before the wake: \(before)")
        let watch = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        clock.release()
        #expect(await returns(watch))
        let after = model.rowPresentations()[0].secondaryText
        #expect(after.contains("2027"), "a date with its year, not a relative phrase: \(after)")
        #expect(!after.contains("ago") && !after.contains("wk"))
        #expect(clock.sleeps.count == 1)
    }

    // MARK: The wake lands after the boundary, by a little

    @Test func theWakeLandsJustPastTheBoundaryNotOnItAndNotAFullStepLate() async {
        let (model, clock) = make(ages: [30])
        await model.open(target: nil)
        let watch = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        let asked = clock.sleeps[0]
        #expect(asked > 1.0 && asked < 1.5, "the label is due in 1 s; asked for \(asked)")
        watch.cancel()
        _ = await returns(watch)
    }

    // MARK: Cancellation and hide

    @Test func aCancelledWatchWakesWithoutRefreshingTheRowsAndDoesNotSleepAgain() async {
        let (model, clock) = make(ages: [120])
        await model.open(target: nil)
        let watch = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        watch.cancel()
        #expect(await returns(watch))
        #expect(model.timeRevision == 0, "a cancelled watch must not bump the revision on its way out")
        #expect(clock.sleeps.count == 1)
    }

    @Test func aHideAndReShowBeforeTheWakeStartsOneFreshSleepFromTheNewReading() async {
        let (model, clock) = make(ages: [120])
        await model.open(target: nil)
        let first = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        #expect(abs(clock.sleeps[0] - 60.05) < 0.5, "2m old: the next minute is 60 s away")

        model.panelDidHide()
        first.cancel()  // what the view does when the task id changes
        #expect(await returns(first))
        clock.advance(by: 30)  // time passes while hidden
        await model.open(target: nil)
        let second = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        #expect(clock.sleeps.count == 2, "one fresh sleep, no leftover from the first watch")
        #expect(abs(clock.sleeps[1] - 30.05) < 0.5, "showing read the clock afresh: 2m30s old, 30 s to the minute")
        #expect(model.timeRevision == 0)
        #expect(model.rowPresentations()[0].secondaryText == "Notes · 2m ago")
        second.cancel()
        _ = await returns(second)
    }

    @Test func anEmptyLibraryNeverSchedulesAWakeup() async {
        let (model, clock) = make(ages: [])
        await model.open(target: nil)
        #expect(model.loadedRows.isEmpty)
        #expect(await returns(Task { await model.watchRelativeTimes() }), "nothing to age: the watch ends at once")
        #expect(clock.sleeps.isEmpty)
    }

    // MARK: Only the rows on screen set the pace

    @Test func rowsLoadedButNotYetVisibleDoNotSetTheSleepAndRevealingThemRestartsTheWatch() async {
        // 50 old rows fill the first screenful; 30 young ones are loaded but sit past the visible limit.
        let (model, clock) = make(ages: Array(repeating: 2.5 * 86_400, count: 50) + Array(repeating: 30, count: 30))
        await model.open(target: nil)
        #expect(model.loadedRows.count == 80)
        #expect(model.visibleRows.count == 50)
        let before = model.relativeTimeWatchKey
        let first = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        #expect(clock.sleeps[0] > 43_200 && clock.sleeps[0] < 43_201, "a day-old pace, not the hidden rows' 1 s: \(clock.sleeps[0])")

        model.loadMore()  // reveals the young rows with no new page, so loadedRows does not change
        #expect(model.visibleRows.count == 80)
        #expect(model.relativeTimeWatchKey != before, "revealing rows must restart the watch")
        first.cancel()  // what the view does when the task id changes
        #expect(await returns(first))
        let second = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        #expect(clock.sleeps[1] > 1.0 && clock.sleeps[1] < 1.5, "the revealed 30 s-old rows now set the pace: \(clock.sleeps[1])")
        second.cancel()
        _ = await returns(second)
    }

    // MARK: Clock jumps

    @Test func aClockJumpedBackwardReadsNowAndKeepsExactlyOneSleeperRunning() async {
        let (model, clock) = make(ages: [120])
        await model.open(target: nil)
        let watch = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        clock.advance(by: -3_600)  // the copy is now an hour in the future
        clock.release()
        #expect(await waitFor { model.timeRevision == 1 })
        #expect(model.rowPresentations()[0].secondaryText == "Notes · now", "a future copy reads as now, never 'in 1h'")
        #expect(await waitFor { clock.parked == 1 }, "the watch goes on, with one sleeper")
        #expect(clock.sleeps.count == 2)
        #expect(clock.sleeps[1] > 0.5, "a positive sleep, never a spin")
        watch.cancel()
        _ = await returns(watch)
    }

    @Test func aClockJumpedForwardIsReadFromTheClockAtTheWakeNotFromAccumulatedSleeps() async {
        let (model, clock) = make(ages: [120])
        await model.open(target: nil)
        let watch = Task { await model.watchRelativeTimes() }
        #expect(await waitFor { clock.parked == 1 })
        clock.advance(by: 7_200)
        clock.release()
        #expect(await waitFor { model.timeRevision == 1 })
        #expect(model.rowPresentations()[0].secondaryText == "Notes · 2h ago")
        watch.cancel()
        _ = await returns(watch)
    }

    // MARK: One clock reading per pass

    @Test func everyRowAndBothStringsOfAPassComeFromOneClockReading() async {
        let ticking = TickingClock(Self.start, step: 30)
        let rows = (0..<3).map { makeRow($0, copiedAt: Self.start.addingTimeInterval(-29.5)) }
        let model = LibraryViewModel(
            source: FakeSource(rows: rows, counts: nil), paster: FakePaster(), host: FakeHost(),
            preferences: FakePreferences(), clock: ticking)
        await model.open(target: nil)
        let readsBefore = ticking.reads
        let pass = model.rowPresentations()
        #expect(pass.count == 3)
        #expect(Set(pass.map(\.secondaryText)).count == 1, "three copies of equal age read alike: \(pass.map(\.secondaryText))")
        for row in pass {
            let visible = row.secondaryText.replacingOccurrences(of: "Notes · ", with: "")
            #expect(row.accessibilityLabel.contains(visible), "spoken \(row.accessibilityLabel) vs shown \(visible)")
        }
        #expect(ticking.reads - readsBefore == 1, "one reading per pass")
    }

    // MARK: Hide, show, hide leaves one watch at a time (WORF-525-F4 re-QA)

    @Test func hideShowHideLeavesNoWatchLiveAndNeverTwoAtOnce() async {
        let (model, clock) = make(ages: [120])
        await model.open(target: nil)
        let first = Task { await model.runRelativeTimeWatch() }
        #expect(await waitFor { clock.parked == 1 })
        model.panelDidHide()
        #expect(await returns(first), "hide #1 ends the first watch")
        #expect(clock.parked == 0)

        await model.open(target: nil)
        let second = Task { await model.runRelativeTimeWatch() }
        #expect(await waitFor { clock.parked == 1 && clock.sleeps.count == 2 })
        model.panelDidHide()
        #expect(await returns(second), "hide #2 ends the second watch")
        #expect(clock.parked == 0)
        #expect(clock.sleeps.count == 2, "no third sleep was started by either hide")
        #expect(model.timeRevision == 0, "no cancelled watch bumped the rows")
    }

    @Test func hidingBeforeTheWatchTaskFirstRunsStartsNoSleepAtAll() async {
        let (model, clock) = make(ages: [120])
        await model.open(target: nil)
        model.panelDidHide()
        let watch = Task { await model.runRelativeTimeWatch() }
        #expect(await returns(watch), "a watch started on a hidden panel returns at once")
        #expect(clock.sleeps.isEmpty)
    }

    /// The view restarts the watch only when `relativeTimeWatchKey` changes. `panelDidHide` cancels the model's task, so a
    /// show must change the key again or a view that never saw the hidden key would keep a dead watch.
    @Test func theWatchKeyDiffersAfterEveryShowEvenWithIdenticalRows() async {
        let (model, _) = make(ages: [120])
        await model.open(target: nil)
        let firstShow = model.relativeTimeWatchKey
        model.panelDidHide()
        await model.open(target: nil)
        let secondShow = model.relativeTimeWatchKey
        #expect(firstShow != secondShow, "same rows, same limit, shown again: the key must still change")
    }

    // MARK: Re-QA of the calendar rule (WORF-525 round 2)

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// Lord Howe shifts by 30 minutes, so the calendar-day boundary (23.5 h after the copy) falls between two whole-hour
    /// steps. A copy made 2026-10-03 12:00 LHST reads "Yesterday" from 2026-10-04 12:00 LHDT, 84,600 s later.
    @Test func aHalfHourDaylightShiftWakesAtTheDayBoundaryNotAtTheNextWholeHour() {
        let lordHowe = calendar("Australia/Lord_Howe")
        let copied = utc("2026-10-03T01:30:00Z")
        let now = copied.addingTimeInterval(83_400)  // 23 h 10 min: "23h ago", next whole-hour step is 3,000 s away
        #expect(ItemSpeech.relativeTime(copied, now: now, calendar: lordHowe) == "23h ago")
        #expect(ItemSpeech.secondsUntilRelativeTimeChanges(copied, now: now, calendar: lordHowe) == 1_200)
        #expect(ItemSpeech.relativeTime(copied, now: now.addingTimeInterval(1_199), calendar: lordHowe) == "23h ago")
        #expect(ItemSpeech.relativeTime(copied, now: now.addingTimeInterval(1_200), calendar: lordHowe) == "Yesterday")
    }

    /// The window is 604,800 s exactly: a copy that old still reads relatively; one second more and it is a date.
    @Test func aCopyExactlySevenDaysOldStillSchedulesAndOneSecondOlderDoesNot() {
        let utcCalendar = calendar("UTC")
        let now = Self.start
        #expect(ItemSpeech.secondsUntilRelativeTimeChanges(now.addingTimeInterval(-604_800), now: now, calendar: utcCalendar) != nil)
        #expect(ItemSpeech.secondsUntilRelativeTimeChanges(now.addingTimeInterval(-604_801), now: now, calendar: utcCalendar) == nil)
    }

    /// WORF-525-F7: the 7-day cutoff is 604,800 s, but the day step counts calendar days. Where a daylight-saving change
    /// falls inside the week, the last "7d ago" turns into a date up to 23 h before the next calendar-day wake.
    @Test func theLastDayLabelTurnsIntoADateAtTheSevenDayCutoffNotAFullDayLate() {
        let newYork = calendar("America/New_York")
        let copied = utc("2026-03-01T15:00:00Z")  // 10:00 EST
        let now = utc("2026-03-08T14:00:00Z")  // 10:00 EDT: 7 calendar days, 601,200 s old
        let before = ItemSpeech.relativeTime(copied, now: now, calendar: newYork)
        let after = ItemSpeech.relativeTime(copied, now: now.addingTimeInterval(3_601), calendar: newYork)
        #expect(before != after, "the label changes within 3,601 s (the copy turns 604,800 s old)")
        let delay = ItemSpeech.secondsUntilRelativeTimeChanges(copied, now: now, calendar: newYork)
        withKnownIssue("WORF-525-F7: the day step overshoots the 7-day cutoff by 23 h across a spring-forward week") {
            #expect((delay ?? 0) <= 3_601)
        }
    }

    // MARK: Future-dated rows (WORF-525-F2)

    @Test func aFutureDatedRowIsNotPolledEverySecondForNothing() {
        let now = Self.start
        // +1 h in the future the label reads "now" until the clock passes the copy time, then "1s ago" a second later.
        #expect(ItemSpeech.secondsUntilRelativeTimeChanges(now.addingTimeInterval(3_600), now: now) == 3_601)
    }
}
