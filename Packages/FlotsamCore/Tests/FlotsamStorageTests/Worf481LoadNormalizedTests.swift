import Foundation
import Testing
@testable import FlotsamStorage

// TASK-481 (Worf). `loadNormalized` rescales a wall-clock figure by the CPU share the probe thread was given. The risk
// it must not run: discounting real slowness so a regression reads as fast. These tests pin the properties the
// builder's own tests do not touch (they only exercise it through the timing tests, which pass on any value <= the bound).

private struct Boom: Error {}

/// Burns `seconds` of this thread's CPU time without suspending (no `await`, so the work stays on one thread).
private func burnCPU(seconds: Double) {
    func cpuNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
    let start = cpuNanos()
    var acc: UInt64 = 1
    while Double(cpuNanos() - start) < seconds * 1e9 {
        for _ in 0..<2_000 { acc = acc &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
    }
    if acc == 0 { print(acc) }
}

@Suite("TASK-481 loadNormalized", .serialized)
struct Worf481LoadNormalizedTests {
    /// OC-W481-01. Given work that costs 150 ms of CPU, the figure it reports (its wall time) comes back scaled by the
    /// share but never below a third of the CPU actually spent and never above the wall time itself: CPU-bound slowness
    /// survives normalization at any load, which is what lets a real regression stay red.
    /// Red if the factor is replaced by a constant (e.g. `wall * 0.02` reads 3 ms) or if the result exceeds its input.
    @Test("OC-W481-01 CPU-bound work of 150 ms reads at least 50 ms and at most its own wall time after normalization")
    func cpuBoundWorkSurvivesNormalization() async throws {
        // given work that burns 150 ms of CPU and reports its wall time
        var wall = 0.0
        // when it is load-normalized
        let normalized = try await loadNormalized {
            let clock = ContinuousClock()
            let elapsed = clock.measure { burnCPU(seconds: 0.150) }
            wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return wall
        }
        // then it is at least a third of the CPU spent (0.050 s) and no more than the raw wall time
        #expect(wall >= 0.150, "the work cannot finish in less wall time than its CPU time: \(wall)")
        #expect(normalized >= 0.050, "normalized \(normalized) s hides 150 ms of CPU-bound work (wall \(wall) s)")
        #expect(normalized <= wall, "normalization increased the figure: \(normalized) > \(wall)")
    }

    /// OC-W481-02 (negative). Given work that throws, the error reaches the caller unchanged, and the next call on a
    /// fresh probe still works (the failed run left no probe state behind).
    /// Red if the error is swallowed, wrapped, or the throw path wedges the next call.
    @Test("OC-W481-02 a throwing run rethrows its own error and the next normalization still returns a value in (0, input]")
    func throwingRunRethrowsAndLeavesNoState() async throws {
        // given a run that throws
        // when it is normalized
        var caught: Error?
        do { _ = try await loadNormalized { throw Boom() } } catch { caught = error }
        // then the caller sees that error
        #expect(caught is Boom, "got \(String(describing: caught))")
        // and a following call returns a figure between the floor and the input (boundary: 0.02 * 10 = 0.2)
        let next = try await loadNormalized { 10.0 }
        #expect(next >= 0.2 && next <= 10.0, "next result \(next)")
    }
}
