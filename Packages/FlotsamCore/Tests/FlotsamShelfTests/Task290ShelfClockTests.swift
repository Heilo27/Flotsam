import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf

// TASK-290 / TASK-440: the Shelf's two timers, driven by a clock the test advances by hand. No test here waits on the
// wall clock: `ShelfManualClock.advance(by:)` wakes the sleepers whose time has come and nothing else does.

/// A clock that only moves when the test says so. `sleep` suspends until `advance` passes its due time, or returns
/// early when the sleeping task is cancelled (the `ShelfClock` contract).
final class ShelfManualClock: ShelfClock, @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let due: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private enum Arrival { case park, resumeNow, cancelNow }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [Sleeper] = []
    private var nextID = 0
    private var cancelledEarly: Set<Int> = []

    let start: Date

    init(start: Date = Date(timeIntervalSinceReferenceDate: 1_000_000)) {
        self.start = start
        current = start
    }

    var now: Date { lock.withLock { current } }
    /// Seconds since the clock was created.
    var elapsed: TimeInterval { now.timeIntervalSince(start) }
    /// Timers currently waiting.
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(for seconds: TimeInterval) async {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let arrival = lock.withLock { () -> Arrival in
                    if cancelledEarly.remove(id) != nil { return .cancelNow }
                    let due = current.addingTimeInterval(seconds)
                    if due <= current { return .resumeNow }
                    sleepers.append(Sleeper(id: id, due: due, continuation: continuation))
                    return .park
                }
                switch arrival {
                case .park: break
                case .resumeNow: continuation.resume()
                case .cancelNow: continuation.resume()
                }
            }
        } onCancel: {
            let parked = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                if let index = sleepers.firstIndex(where: { $0.id == id }) { return sleepers.remove(at: index).continuation }
                cancelledEarly.insert(id)
                return nil
            }
            parked?.resume()
        }
    }

    /// Lets other tasks run until `sleeperCount == count`, so a test knows a timer is armed before it advances. The
    /// timer task reaches the clock after hops through the cooperative pool, which a loaded machine (the whole suite
    /// running in parallel) can starve for a while, so the failure cap is a generous wall-clock limit, not a yield
    /// count. It never delays a passing run: it returns the moment the count is reached.
    func waitForSleepers(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var round = 0
        while ContinuousClock.now < deadline {
            if sleeperCount == count { return true }
            round += 1
            if round % 16 == 0 { await Task.detached {}.value } else { await Task.yield() }
        }
        return sleeperCount == count
    }

    private func settle() async {
        for round in 0..<200 {
            if round % 16 == 15 { await Task.detached {}.value } else { await Task.yield() }
        }
    }

    /// Moves time forward by `seconds`, waking each sleeper at its own due time, earliest first, and letting the woken
    /// task run (and re-arm) before the next is considered.
    func advance(by seconds: TimeInterval) async {
        let target = lock.withLock { current.addingTimeInterval(seconds) }
        while true {
            await settle()
            let next = lock.withLock { () -> Sleeper? in
                guard let index = sleepers.indices.min(by: { sleepers[$0].due < sleepers[$1].due }),
                      sleepers[index].due <= target else { return nil }
                let sleeper = sleepers.remove(at: index)
                current = max(current, sleeper.due)
                return sleeper
            }
            guard let next else { break }
            next.continuation.resume()
        }
        lock.withLock { current = target }
        await settle()
    }
}

/// Lets other tasks run until `condition` holds. A woken timer task resumes off the main actor and hops back, which
/// takes real scheduler time, so a fixed number of yields is not enough under load: this waits for the observable
/// outcome instead. Bounded by a generous wall-clock cap (30 s, reached only on failure): a condition that never holds fails the caller's
/// `#expect` rather than hanging. Used for positive outcomes only (a negative "nothing happened yet" check cannot be
/// made late-proof, and cannot go red because of lateness).
@MainActor
private func until(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    var round = 0
    while ContinuousClock.now < deadline {
        if condition() { return true }
        round += 1
        if round % 16 == 0 { await Task.detached {}.value } else { await Task.yield() }
    }
    return condition()
}

@MainActor
private final class Commands {
    var all: [ShelfRevealMachine.Command] = []
    /// Returns the commands performed since the last call.
    func drain() -> [ShelfRevealMachine.Command] {
        defer { all = [] }
        return all
    }
}

@MainActor
private struct DriverRig {
    let clock = ShelfManualClock()
    let commands = Commands()
    let driver: ShelfRevealDriver

    init() {
        let commands = commands
        driver = ShelfRevealDriver(clock: clock)
        driver.perform = { commands.all += $0 }
        driver.send(.configure(enabled: true, placement: .rightEdge, revealOnEdgeHover: false))
    }

    /// A drag arrives at the edge of screen 0 and the drag dwell starts.
    func dragToEdge() async {
        driver.send(.dragging(true))
        driver.send(.pointer(.edgeZone(screen: 0)))
        _ = await clock.waitForSleepers(1)
    }

    /// Advances past the dwell and waits for the reveal to be performed, then clears the record.
    func revealShelf() async {
        await dragToEdge()
        await clock.advance(by: 0.31)
        _ = await until { !commands.all.isEmpty }
        _ = commands.drain()
    }
}

@MainActor
@Suite struct ShelfRevealDriverClockTests {
    @Test("OC-6115 an idle Shelf has no timer armed: configured, nothing pending, no task and no sleeper")
    func idleMeansNoTimer() async {
        let rig = DriverRig()
        #expect(rig.driver.machine.nextDeadline == nil)
        #expect(!rig.driver.isTimerArmed)
        await rig.clock.advance(by: 60)
        #expect(rig.clock.sleeperCount == 0 && rig.commands.drain().isEmpty)
        rig.driver.send(.pointer(.away))
        rig.driver.send(.buttonDown(true))
        #expect(!rig.driver.isTimerArmed, "events that start nothing must not arm a timer")
    }

    @Test("OC-6068 a drag held at the edge for 0.3 s reveals the Shelf, and not a moment earlier")
    func dragDwellReveals() async {
        let rig = DriverRig()
        await rig.dragToEdge()
        #expect(rig.driver.isTimerArmed)
        #expect(await rig.clock.waitForSleepers(1))
        await rig.clock.advance(by: 0.29)
        #expect(rig.commands.drain().isEmpty && !rig.driver.machine.isVisible)
        await rig.clock.advance(by: 0.02)
        #expect(await until { rig.commands.all == [.show(trigger: .drag, screen: 0)] })
        #expect(rig.driver.machine.isVisible)
    }

    @Test("FR-006-17 a drag that leaves before the dwell is over cancels the reveal and the timer")
    func leavingCancelsTheDwell() async {
        let rig = DriverRig()
        await rig.dragToEdge()
        #expect(await rig.clock.waitForSleepers(1))
        await rig.clock.advance(by: 0.2)
        rig.driver.send(.pointer(.away))
        #expect(!rig.driver.isTimerArmed)
        #expect(await rig.clock.waitForSleepers(0), "the cancelled timer is still sleeping")
        await rig.clock.advance(by: 5)
        #expect(rig.commands.drain().isEmpty && !rig.driver.machine.isVisible)
    }

    @Test("FR-006-17 only one timer is ever armed: a new event replaces the old one, and the dwell restarts on a new screen")
    func oneTimerAtATime() async {
        let rig = DriverRig()
        await rig.dragToEdge()
        #expect(await rig.clock.waitForSleepers(1))
        await rig.clock.advance(by: 0.2)
        rig.driver.send(.pointer(.edgeZone(screen: 1)))
        #expect(await rig.clock.waitForSleepers(1), "the old timer must be cancelled when the new one is armed")
        await rig.clock.advance(by: 0.29)
        #expect(rig.commands.drain().isEmpty, "the new screen's dwell restarted at the move")
        await rig.clock.advance(by: 0.02)
        #expect(await until { rig.commands.all == [.show(trigger: .drag, screen: 1)] })
    }

    @Test("FR-006-17 a transient Shelf the pointer is on has no timer; leaving it hides after 0.6 s")
    func transientHideDelay() async {
        let rig = DriverRig()
        await rig.revealShelf()
        rig.driver.send(.pointer(.onShelf))
        #expect(!rig.driver.isTimerArmed, "pointer on the Shelf: nothing to wait for")
        #expect(await rig.clock.waitForSleepers(0))
        rig.driver.send(.dragging(false))
        rig.driver.send(.pointer(.away))
        #expect(rig.driver.isTimerArmed)
        #expect(await rig.clock.waitForSleepers(1))
        await rig.clock.advance(by: 0.59)
        #expect(rig.commands.all.isEmpty && rig.driver.machine.isVisible)
        await rig.clock.advance(by: 0.02)
        #expect(await until { rig.commands.all == [.hide] })
        #expect(!rig.driver.isTimerArmed, "after the hide the Shelf is idle again")
    }

    @Test("OC-6110 after a drop the Shelf stays 1.5 s longer: visible at 2.0 s, hidden by 2.2 s, with the pointer away")
    func dropHoldThroughTheClock() async {
        let rig = DriverRig()
        await rig.revealShelf()
        rig.driver.send(.pointer(.onShelf))
        rig.driver.send(.dropCompleted)
        rig.driver.send(.dragging(false))
        rig.driver.send(.pointer(.away))
        #expect(await rig.clock.waitForSleepers(1))
        await rig.clock.advance(by: 1.4)
        #expect(rig.commands.all.isEmpty && rig.driver.machine.isVisible, "hidden before the drop hold ended")
        await rig.clock.advance(by: 0.6)
        #expect(rig.commands.all.isEmpty && rig.driver.machine.isVisible, "hidden at 2.0 s, before the 2.1 s the hold allows")
        await rig.clock.advance(by: 0.2)
        #expect(await until { rig.commands.all == [.hide] })
        #expect(!rig.driver.machine.isVisible && !rig.driver.isTimerArmed)
    }

    @Test("OC-6110 a drop with the pointer still on the Shelf holds nothing: the leave timer starts when the pointer goes")
    func dropThenLeaveLater() async {
        let rig = DriverRig()
        await rig.revealShelf()
        rig.driver.send(.pointer(.onShelf))
        rig.driver.send(.dropCompleted)
        rig.driver.send(.dragging(false))
        await rig.clock.advance(by: 10)
        #expect(rig.commands.all.isEmpty && rig.driver.machine.isVisible, "the pointer is on the Shelf")
        rig.driver.send(.pointer(.away))
        #expect(await rig.clock.waitForSleepers(1))
        await rig.clock.advance(by: 0.59)
        #expect(rig.commands.all.isEmpty)
        await rig.clock.advance(by: 0.02)
        #expect(await until { rig.commands.all == [.hide] })
    }
}

@MainActor
@Suite struct ShelfHighlightTimerClockTests {
    private func rows(_ numbers: Range<Int>) -> [ItemRow] { numbers.map { makeShelfRow($0) } }

    @Test("OC-6105 the dropped card is highlighted at once and the highlight ends after ShelfLayout.dropHighlightDuration (0.6 s)")
    func highlightExpires() async {
        #expect(ShelfLayout.dropHighlightDuration == 0.6)
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        let clock = ShelfManualClock()
        let timer = ShelfHighlightTimer(model: rig.model, clock: clock)
        #expect(!timer.isTimerArmed)
        timer.highlight(shelfID(2))
        #expect(rig.model.highlightedItemId == shelfID(2))
        #expect(timer.isTimerArmed)
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: 0.59)
        #expect(rig.model.highlightedItemId == shelfID(2), "cleared before 0.6 s")
        await clock.advance(by: 0.02)
        #expect(await until { rig.model.highlightedItemId == nil }, "still highlighted after 0.6 s")
        #expect(!timer.isTimerArmed && clock.sleeperCount == 0)
    }

    @Test("OC-6109 an expiry for an older card never clears a newer card's highlight")
    func staleExpiryKeepsNewerHighlight() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        rig.model.highlight(shelfID(1))
        rig.model.highlight(shelfID(3))
        rig.model.clearHighlight(of: shelfID(1))
        #expect(rig.model.highlightedItemId == shelfID(3), "the first card's expiry cleared the second card's highlight")
        rig.model.clearHighlight(of: shelfID(3))
        #expect(rig.model.highlightedItemId == nil)
    }

    @Test("OC-6109 a second drop on another card keeps its own highlight for its own full 0.6 s")
    func secondDropKeepsItsHighlight() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        let clock = ShelfManualClock()
        let timer = ShelfHighlightTimer(model: rig.model, clock: clock)
        timer.highlight(shelfID(1))
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: 0.4)
        timer.highlight(shelfID(3))
        #expect(rig.model.highlightedItemId == shelfID(3))
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: 0.3)
        #expect(rig.model.highlightedItemId == shelfID(3), "the first drop's expiry cleared the second's highlight")
        await clock.advance(by: 0.29)
        #expect(rig.model.highlightedItemId == shelfID(3), "the second highlight ended before its own 0.6 s")
        await clock.advance(by: 0.02)
        #expect(await until { rig.model.highlightedItemId == nil })
    }

    @Test("OC-6109 a repeat drop on the same card restarts the 0.6 s: the first timer must not end it early")
    func repeatDropRestartsTheTimer() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        let clock = ShelfManualClock()
        let timer = ShelfHighlightTimer(model: rig.model, clock: clock)
        timer.highlight(shelfID(2))
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: 0.4)
        timer.highlight(shelfID(2))
        #expect(await clock.waitForSleepers(1), "the first timer must be cancelled")
        await clock.advance(by: 0.3)
        #expect(rig.model.highlightedItemId == shelfID(2), "the first timer ended the repeat drop's highlight")
        await clock.advance(by: 0.31)
        #expect(await until { rig.model.highlightedItemId == nil })
    }

    @Test("FR-006-15 hiding the Shelf clears the highlight, and the timer firing later does not bring anything back")
    func hideThenExpiry() async {
        let rig = ShelfRig(rows: rows(1..<4))
        await rig.openSticky()
        let clock = ShelfManualClock()
        let timer = ShelfHighlightTimer(model: rig.model, clock: clock)
        timer.highlight(shelfID(2))
        #expect(await clock.waitForSleepers(1))
        rig.model.didHide()
        #expect(rig.model.highlightedItemId == nil)
        await clock.advance(by: 1)
        #expect(rig.model.highlightedItemId == nil)
    }
}
