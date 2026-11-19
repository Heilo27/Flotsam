import FlotsamBase
import Foundation
import Testing
@testable import FlotsamShelf

// TASK-290/440 QA (Worf, blind): behaviour parity of the extracted Shelf timers. Durations are literals from the FRD
// (FR-006-03 dwells 0.3 s drag / 0.5 s hover, FR-006-15 600 ms highlight, 1.5 s hold, 0.6 s leave delay) and the
// oracle (OC-6068, 6105, 6109, 6110, 6115).

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
private final class Sink {
    var commands: [ShelfRevealMachine.Command] = []
}

@MainActor
private func makeDriver(hover: Bool = false) -> (ShelfRevealDriver, ShelfManualClock, Sink) {
    let clock = ShelfManualClock()
    let sink = Sink()
    let driver = ShelfRevealDriver(clock: clock)
    driver.perform = { sink.commands += $0 }
    driver.send(.configure(enabled: true, placement: .rightEdge, revealOnEdgeHover: hover))
    return (driver, clock, sink)
}

@MainActor
@Suite struct Worf290ShelfTimerTests {
    @Test("FR-006-03 hover dwell: an edge hover with no drag reveals at 0.5 s, not 0.49 s")
    func hoverDwell() async {
        let (driver, clock, sink) = makeDriver(hover: true)
        driver.send(.pointer(.edgeZone(screen: 0)))
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: 0.49)
        #expect(sink.commands.isEmpty && !driver.machine.isVisible, "revealed before the 0.5 s hover dwell")
        await clock.advance(by: 0.02)
        #expect(await until { sink.commands.count == 1 && driver.machine.isVisible })
        driver.send(.pointer(.onShelf))
        #expect(await clock.waitForSleepers(0) && !driver.isTimerArmed, "a revealed Shelf under the pointer holds no timer")
    }

    @Test("OC-6115 idle: after the dwell is abandoned, after hide, and after a disable, no timer and no sleeper remain")
    func idleAfterEveryPath() async {
        let (driver, clock, _) = makeDriver()
        #expect(!driver.isTimerArmed && clock.sleeperCount == 0)
        // abandoned dwell
        driver.send(.dragging(true))
        driver.send(.pointer(.edgeZone(screen: 0)))
        #expect(await clock.waitForSleepers(1))
        driver.send(.pointer(.away))
        #expect(await clock.waitForSleepers(0) && !driver.isTimerArmed)
        // dwell pending, then the Shelf is switched off
        driver.send(.pointer(.edgeZone(screen: 0)))
        #expect(await clock.waitForSleepers(1))
        driver.send(.configure(enabled: false, placement: .rightEdge, revealOnEdgeHover: false))
        #expect(await clock.waitForSleepers(0) && !driver.isTimerArmed, "a disabled Shelf kept its dwell timer")
        await clock.advance(by: 5)
        #expect(!driver.machine.isVisible, "the cancelled dwell still revealed the Shelf")
    }

    @Test("FR-006-17 a stale deadline never fires: moving to another screen restarts the 0.3 s dwell from the move")
    func dwellRestartsOnNewScreen() async {
        let (driver, clock, sink) = makeDriver()
        driver.send(.dragging(true))
        driver.send(.pointer(.edgeZone(screen: 0)))
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: 0.2)
        driver.send(.pointer(.edgeZone(screen: 1)))
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: 0.2)   // 0.4 s after the first, 0.2 s after the second
        #expect(sink.commands.isEmpty, "the first screen's deadline fired")
        await clock.advance(by: 0.11)
        #expect(await until { sink.commands == [.show(trigger: .drag, screen: 1)] })
    }

    @Test("OC-6110 1.4 s after the drop the Shelf is still up with the pointer away; one timer armed, none after the hide")
    func dropHoldBoundary() async {
        let (driver, clock, sink) = makeDriver()
        driver.send(.dragging(true))
        driver.send(.pointer(.edgeZone(screen: 0)))
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: 0.31)
        #expect(await until { sink.commands.count == 1 })
        sink.commands = []
        driver.send(.pointer(.onShelf))
        driver.send(.dropCompleted)
        driver.send(.dragging(false))
        driver.send(.pointer(.away))
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: 1.4)
        #expect(driver.machine.isVisible && sink.commands.isEmpty)
        await clock.advance(by: 0.69)   // 2.09 s, one hundredth short of 1.5 s + 0.6 s
        #expect(driver.machine.isVisible && sink.commands.isEmpty, "hidden before hold plus leave delay")
        await clock.advance(by: 0.02)
        #expect(await until { sink.commands == [.hide] })
        #expect(!driver.isTimerArmed && clock.sleeperCount == 0)
    }

    @Test("FR-006-15 the highlight is exactly 0.6 s: 0.59 s still lit, 0.61 s dark, and a later expiry never lights anything")
    func highlightBoundary() async {
        let rig = ShelfRig(rows: (1..<4).map { makeShelfRow($0) })
        await rig.openSticky()
        let clock = ShelfManualClock()
        let timer = ShelfHighlightTimer(model: rig.model, clock: clock)
        timer.highlight(shelfID(3))
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: 0.59)
        #expect(rig.model.highlightedItemId == shelfID(3))
        await clock.advance(by: 0.02)
        #expect(await until { rig.model.highlightedItemId == nil })
        #expect(!timer.isTimerArmed && clock.sleeperCount == 0)
        await clock.advance(by: 10)
        #expect(rig.model.highlightedItemId == nil)
    }

    @Test("FR-006-15 a second drop keeps one sleeper only: the first timer is cancelled, not left armed")
    func highlightOneTimer() async {
        let rig = ShelfRig(rows: (1..<4).map { makeShelfRow($0) })
        await rig.openSticky()
        let clock = ShelfManualClock()
        let timer = ShelfHighlightTimer(model: rig.model, clock: clock)
        timer.highlight(shelfID(1))
        #expect(await clock.waitForSleepers(1))
        timer.highlight(shelfID(2))
        #expect(await clock.waitForSleepers(1), "two highlight timers are armed")
        #expect(rig.model.highlightedItemId == shelfID(2))
    }

    @Test("FR-006-17 SystemShelfClock: cancelling a long sleep returns at once, a zero or negative sleep returns, now is the real time")
    func systemClockContract() async {
        let clock = SystemShelfClock()
        let t0 = ContinuousClock.now
        let sleeper = Task { await clock.sleep(for: 120) }
        try? await Task.sleep(for: .milliseconds(50))
        sleeper.cancel()
        await sleeper.value
        #expect(ContinuousClock.now - t0 < .seconds(20), "cancellation did not end the sleep")
        await clock.sleep(for: 0)
        await clock.sleep(for: -5)
        #expect(abs(clock.now.timeIntervalSinceNow) < 5)
    }

    @Test("FR-006-17 after a reveal with the pointer still at the edge the machine's leave deadline is armed again, and it hides 0.6 s later")
    func rearmAfterDeadline() async {
        let (driver, clock, sink) = makeDriver(hover: true)
        driver.send(.pointer(.edgeZone(screen: 0)))
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: 0.51)
        #expect(await until { sink.commands.count == 1 })
        sink.commands = []
        #expect(await clock.waitForSleepers(1), "the leave timer was not armed after the reveal")
        // The leave clock started at the reveal deadline (0.5 s), so the hide is due at 1.1 s; the clock stands at 0.51 s.
        await clock.advance(by: 0.58)
        #expect(sink.commands.isEmpty && driver.machine.isVisible, "hid before the 0.6 s leave delay")
        await clock.advance(by: 0.02)
        #expect(await until { sink.commands == [.hide] })
        #expect(await clock.waitForSleepers(0) && !driver.isTimerArmed)
    }
}
