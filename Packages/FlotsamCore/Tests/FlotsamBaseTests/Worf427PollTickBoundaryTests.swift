import Foundation
import Testing
@testable import FlotsamBase

@Suite("Worf427 PollTick.every period boundaries")
struct Worf427PollTickBoundaryTests {
    private func runs(_ seconds: TimeInterval, firings: Int) -> [Int] {
        let tick = PollTick()
        let seen = LockedValue<[Int]>([])
        let count = LockedValue(0)
        _ = tick.every(seconds) { seen.withLock { $0.append(count.withLock { $0 }) } }
        for _ in 0..<firings {
            count.withLock { $0 += 1 }
            tick.fire()
        }
        return seen.withLock { $0 }
    }

    /// OC-427-W6. given a period of exactly one tick (0.5 s), it runs on every firing.
    @Test("OC-427-W6 0.5 s runs every tick; just under and just over behave")
    func oneTickBoundary() {
        #expect(runs(0.5, firings: 4) == [1, 2, 3, 4])
        #expect(runs(0.49, firings: 4) == [1, 2, 3, 4])
        #expect(runs(0.25, firings: 3) == [1, 2, 3])
        #expect(runs(0.76, firings: 6) == [2, 4, 6], "0.76 s rounds to 2 ticks")
        #expect(runs(1.0, firings: 6) == [2, 4, 6])
    }

    /// OC-427-W7. given exactly maxPeriod, it runs on the 172,800th tick and not before; one tick short it has not run.
    /// A period beyond it (and infinity) lands on the same tick.
    @Test("OC-427-W7 maxPeriod runs on the 172800th tick; anything longer is clamped to it")
    func maxPeriodBoundary() {
        #expect(PollTick.maxPeriod == 86_400)
        #expect(runs(86_400, firings: 172_799).isEmpty)
        #expect(runs(86_400, firings: 172_800) == [172_800])
        #expect(runs(86_400.5, firings: 172_800) == [172_800])
        #expect(runs(1e300, firings: 172_800) == [172_800])
        #expect(runs(.infinity, firings: 172_800) == [172_800])
        #expect(runs(86_399, firings: 172_798) == [172_798])
    }
}
