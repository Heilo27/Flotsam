import FlotsamBase
import Foundation
import Testing
@testable import FlotsamTriggers

/// FR-005-19: three disablements within 60 seconds latch the tap off; the latch lifts only when triggers are toggled
/// off, and a relaunch (a new `TapHealth`) starts clear.
@Suite struct TapHealthTests {
    private let clock = ManualClock()
    private let health: TapHealth

    init() { health = TapHealth(clock: clock) }

    @Test func theFirstTwoDisablementsAreReenabled() {
        #expect(health.recordDisable() == .reenable)
        #expect(health.recordDisable() == .reenable)
        #expect(!health.isLatched)
    }

    @Test func theThirdDisablementInsideSixtySecondsLatches() {
        health.recordDisable()
        clock.advance(25)
        health.recordDisable()
        clock.advance(25)
        #expect(health.recordDisable() == .latch)
        #expect(health.isLatched)
    }

    @Test func disablementsSpacedOverSixtySecondsNeverLatch() {
        // Each trio spans more than 60 s: 0, 40, 81 and then 121, 162.
        for gap in [0.0, 40, 41, 40, 41] {
            clock.advance(gap)
            #expect(health.recordDisable() == .reenable)
        }
        #expect(!health.isLatched)
    }

    @Test func aDisablementJustInsideTheWindowStillCounts() {
        health.recordDisable()
        clock.advance(30)
        health.recordDisable()
        clock.advance(29)  // 59 s after the first
        #expect(health.recordDisable() == .latch)
    }

    @Test func onceLatchedTimeDoesNotLiftIt() {
        for _ in 0..<3 { health.recordDisable() }
        clock.advance(3_600)
        #expect(health.isLatched)
        #expect(health.recordDisable() == .latch)
    }

    @Test func resetLiftsTheLatchAndForgetsTheHistory() {
        for _ in 0..<3 { health.recordDisable() }
        #expect(health.isLatched)

        health.reset()

        #expect(!health.isLatched)
        // History is gone too: it takes three new disablements to latch again, not one.
        #expect(health.recordDisable() == .reenable)
        #expect(health.recordDisable() == .reenable)
        #expect(health.recordDisable() == .latch)
    }

    @Test func aNewInstanceStartsClearAsARelaunchDoes() {
        for _ in 0..<3 { health.recordDisable() }
        let relaunched = TapHealth(clock: clock)
        #expect(!relaunched.isLatched)
        #expect(relaunched.recordDisable() == .reenable)
    }
}
