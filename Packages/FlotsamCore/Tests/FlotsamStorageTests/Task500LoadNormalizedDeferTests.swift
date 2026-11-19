import Foundation
import Testing
@testable import FlotsamStorage

// TASK-500 (TASK-481 Worf, W4). `loadNormalized` starts a spinning probe thread and must end it when `run` throws: a
// leaked spinner would burn a core for the rest of the test run and skew every later share. The probe is passed in so
// the test can read its liveness afterwards.

private struct Thrown: Error {}

@Suite("TASK-500 loadNormalized ends its probe", .serialized)
struct Task500LoadNormalizedDeferTests {
    /// Given a run that throws, then the spin thread was live while the run executed and was told to stop by the time the
    /// error reaches the caller. Red if the `defer { _ = probe.stop() }` in `loadNormalized` is removed.
    @Test("a throwing run still ends the spin thread")
    func throwingRunEndsTheSpinThread() async {
        let probe = CPUShareProbe()
        #expect(!probe.stopWasRequested, "the probe must be live before the run, or the check below proves nothing")
        var runSawLiveProbe = false

        var caught: Error?
        do {
            _ = try await loadNormalized(probe: probe) {
                runSawLiveProbe = !probe.stopWasRequested
                throw Thrown()
            }
        } catch { caught = error }

        #expect(caught is Thrown, "got \(String(describing: caught))")
        #expect(runSawLiveProbe, "the probe was already stopped while the run executed")
        #expect(probe.stopWasRequested, "the run threw and the spin thread was never told to stop")
    }

    /// The same check on the normal path, so the throw-path assertion above is known to be about the `defer` and not
    /// about the probe ending for some other reason.
    @Test("a returning run ends the spin thread too")
    func returningRunEndsTheSpinThread() async throws {
        let probe = CPUShareProbe()
        _ = try await loadNormalized(probe: probe) { 1.0 }
        #expect(probe.stopWasRequested)
    }
}
