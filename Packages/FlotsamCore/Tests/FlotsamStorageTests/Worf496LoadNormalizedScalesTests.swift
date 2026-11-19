import Foundation
import Testing
@testable import FlotsamStorage

// TASK-496 (Worf). `loadNormalized` is the mechanism the OC-4230 de-flake leans on: under load its figure must be scaled
// DOWN. The TASK-481 tests pin only the bounds (at least a third of the CPU spent, never above the wall time), and a
// helper that returns the raw wall figure satisfies both, so a helper that stopped normalizing at all would stay green
// while OC-4230 went back to failing under load. This test makes the scaling observable by creating the load itself.

@Suite("TASK-496 loadNormalized scales down under CPU contention", .serialized)
struct Worf496LoadNormalizedScalesTests {
    /// OC-W496-01. Given four times as many busy threads as cores for the whole of a 0.5 s run, when the run's wall
    /// figure is load-normalized, then the result is well under the raw wall figure (the probe thread was starved).
    /// Red if `loadNormalized` returns the unscaled wall figure. (The 0.02 floor is not reachable at this contention,
    /// so it is not pinned here.)
    @Test("OC-W496-01 under 4x CPU oversubscription the normalized figure is below 0.8 of the wall figure and above zero")
    func scalesDownUnderContention() async throws {
        // given: 4 spinners per core, running until released
        let stop = Locked(false)
        let spinners = (0..<(ProcessInfo.processInfo.activeProcessorCount * 4)).map { _ in
            Thread {
                var acc: UInt64 = 1
                while !stop.value {
                    for _ in 0..<20_000 { acc = acc &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
                }
                if acc == 0 { print(acc) }
            }
        }
        spinners.forEach { $0.start() }
        defer { stop.mutate { $0 = true } }
        try await Task.sleep(for: .milliseconds(100))

        // when: a run whose figure is 0.5 s of wall time is normalized
        let wall = 0.5
        let normalized = await loadNormalized {
            try? await Task.sleep(for: .milliseconds(500))
            return wall
        }

        // then: the figure was scaled down and is still positive
        #expect(normalized < wall * 0.8, "normalized \(normalized) s is not below 0.8 of the \(wall) s wall figure")
        #expect(normalized > 0, "normalized \(normalized) s is not positive")
    }
}
