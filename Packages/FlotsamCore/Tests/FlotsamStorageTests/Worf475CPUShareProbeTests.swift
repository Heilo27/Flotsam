import Foundation
import Testing
@testable import FlotsamStorage

// TASK-475 delta re-check (Worf). CPUShareProbe.stop() was made idempotent (re-signals `finished`) so a `defer`
// can end the spin thread on a throwing clear while the happy path still reads the share afterwards.

private struct Boom: Error {}

/// Runs `body` off the test task and reports whether it finished inside `seconds`. A hung `stop()` blocks its own
/// thread forever; the test sees a timeout instead of hanging the suite.
private func finishes(within seconds: Double, _ body: @escaping @Sendable () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    let thread = Thread { body(); done.signal() }
    thread.start()
    return done.wait(timeout: .now() + seconds) == .success
}

@Suite("TASK-475 CPUShareProbe stop() idempotence", .serialized)
struct Worf475CPUShareProbeTests {
    /// OC-7098 (support). Red if a second stop() blocks (semaphore not re-signalled) or returns a different value
    /// than the first (share recomputed or reset on the second call).
    @Test("OC-7098-W1 stop() called twice returns the same share both times and the second call does not hang")
    func stopTwiceSameShareNoHang() {
        // given a probe that has been spinning for a short window
        let probe = CPUShareProbe()
        Thread.sleep(forTimeInterval: 0.15)
        let results = Locked<[Double]>([])

        // when stop() is called twice in a row
        let finished = finishes(within: 10) {
            results.mutate { $0.append(probe.stop()) }
            results.mutate { $0.append(probe.stop()) }
        }

        // then neither call hung, both returned a share in (0, 1], and the two values are identical
        #expect(finished, "second stop() hung")
        #expect(results.value.count == 2)
        if results.value.count == 2 {
            #expect(results.value[0] > 0 && results.value[0] <= 1.0)
            #expect(results.value[1] == results.value[0])
        }
    }

    /// Red if three stop() calls (defer + trailing + extra) exhaust a single re-signal, or the count drifts.
    @Test("OC-7098-W2 stop() called five times never hangs and never changes its answer")
    func stopFiveTimes() {
        // given a probe stopped once
        let probe = CPUShareProbe()
        Thread.sleep(forTimeInterval: 0.1)
        let first = probe.stop()
        let results = Locked<[Double]>([])

        // when stopped four more times
        let finished = finishes(within: 10) { for _ in 0..<4 { results.mutate { $0.append(probe.stop()) } } }

        // then all four returned and each equals the first
        #expect(finished, "a later stop() hung")
        #expect(results.value.count == 4)
        #expect(results.value.allSatisfy { $0 == first })
    }

    /// Red if two racing stop() calls (a defer firing while another reader reads) leave one waiter stuck or return a
    /// half-written share.
    @Test("OC-7098-W3 two threads calling stop() at once both return, with the same share")
    func concurrentStops() {
        // given a spinning probe and two threads that will both stop it
        let probe = CPUShareProbe()
        Thread.sleep(forTimeInterval: 0.1)
        let results = Locked<[Double]>([])
        let both = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            Thread { results.mutate { $0.append(probe.stop()) }; both.signal() }.start()
        }

        // when we wait for both
        let a = both.wait(timeout: .now() + 10)
        let b = both.wait(timeout: .now() + 10)

        // then neither is stuck and the two shares are equal and in (0, 1]
        #expect(a == .success && b == .success, "a racing stop() hung")
        #expect(results.value.count == 2)
        if results.value.count == 2 {
            #expect(results.value[0] == results.value[1])
            #expect(results.value[0] > 0 && results.value[0] <= 1.0)
        }
    }

    /// Red if the stop window is not honoured: a window that spun ~0.3 s on an otherwise idle test thread must read a
    /// share well above the 0.02 floor the OC-7098 budget clamps to, so a stub returning the floor or 0 fails.
    @Test("OC-7098-W4 a stopped probe reports a share above the 0.02 floor and at most 1 (boundary: not 0, not >1)")
    func shareIsInRange() {
        // given a 0.3 s window
        let probe = CPUShareProbe()
        Thread.sleep(forTimeInterval: 0.3)

        // when stopped
        let share = probe.stop()

        // then the share is a real fraction, not 0 / NaN / >1
        #expect(share > 0.02, "share \(share)")
        #expect(share <= 1.0)
    }

    /// The throw path as OC-7098 uses it: probe started, `defer { _ = probe.stop() }`, then the work throws.
    /// Red if stop() cannot be ended from a defer and still read afterwards (hang), or if the throw path leaves the
    /// window open. The production `defer` itself is guarded by the mutation check recorded in the TASK-475 note.
    @Test("OC-7098-W5 a throw after the probe starts still ends the window, and stop() afterwards returns at once")
    func throwAfterStartEndsProbe() {
        // given a function shaped like the OC-7098 body: start probe, defer stop, then throw
        let box = Locked<[CPUShareProbe]>([])
        func clearThatThrows() throws {
            let probe = CPUShareProbe()
            box.mutate { $0.append(probe) }
            defer { _ = probe.stop() }
            Thread.sleep(forTimeInterval: 0.05)
            throw Boom()
        }

        // when it throws
        var threw = false
        do { try clearThatThrows() } catch is Boom { threw = true } catch {}

        // then the throw happened, the deferred stop ended the window, and a later stop() returns a share promptly
        #expect(threw)
        #expect(box.value.count == 1)
        guard let probe = box.value.first else { return }
        #expect(probe.stopWasRequested)
        let later = Locked<Double>(-1)
        let finished = finishes(within: 10) { later.mutate { $0 = probe.stop() } }
        #expect(finished, "stop() after a deferred stop hung")
        #expect(later.value > 0 && later.value <= 1.0)
    }
}
