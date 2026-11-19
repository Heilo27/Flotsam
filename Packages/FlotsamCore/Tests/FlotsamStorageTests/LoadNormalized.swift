import Dispatch
import Foundation

// Shared by symlink with FlotsamLibraryTests (SwiftPM test targets cannot depend on each other), the way
// `SignpostProbe.swift` is shared with FlotsamScreenshotsTests. Edit only this file.

/// How much of a core the machine gave a thread that wanted all of one, over the window between `init` and `stop()`:
/// thread CPU time divided by wall time, 1.0 on an idle machine and small when it is starved. A wall-clock budget
/// multiplied by this is the time the work would have taken with the CPU to itself, so the budget stops depending on
/// how many other processes (or other tests) are running. A sleep or an I/O stall inside the work does not lower the
/// share, so it still counts against the budget in full.
final class CPUShareProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    private var share = 1.0
    private var sink: UInt64 = 0
    private let running = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)

    init() {
        let thread = Thread { [self] in run() }
        thread.start()
        running.wait()
    }

    /// Ends the window and returns the share, in (0, 1]. Safe to call more than once (a `defer` guards the throw
    /// path while the happy path reads the value): the first call ends the window, later calls return the same share.
    func stop() -> Double {
        lock.withLock { stopRequested = true }
        finished.wait()
        finished.signal()
        return lock.withLock { share }
    }

    /// True once `stop()` has asked the spin thread to end (read by the TASK-475 worf tests to see a deferred stop ran).
    var stopWasRequested: Bool { lock.withLock { stopRequested } }

    private static func threadCPUNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }

    private func run() {
        let wall0 = DispatchTime.now().uptimeNanoseconds
        let cpu0 = Self.threadCPUNanos()
        running.signal()
        var acc: UInt64 = 1
        while !lock.withLock({ stopRequested }) {
            for _ in 0..<20_000 { acc = acc &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        }
        sink = acc
        let cpu = Double(Self.threadCPUNanos() - cpu0)
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wall0)
        lock.withLock { share = wall > 0 ? min(1, cpu / wall) : 1 }
        finished.signal()
    }
}

/// A wall-clock figure scaled to the time the work would have taken with the CPU to itself (TASK-481). `run` returns a
/// wall-time figure (a p95, a longest stall); it is multiplied by the CPU share a spinning probe thread was given while
/// `run` executed (`CPUShareProbe`, the OC-7098 mechanism). On a quiet machine the share is 1.0 and the figure is read
/// unchanged; at a load average of 250 on 18 cores the share is a few percent and a 15x-slow-but-correct run reads as the
/// 1x it is. Work that really is slower (an added sleep, a full scan, an I/O stall) does not lower the share, so it still
/// reads its full wall time against the bound. The 0.02 floor matches OC-7098 and caps the allowance at 50x.
///
/// Runs on the caller's actor (`isolation`), so a `@MainActor` test can measure main-actor work inside `run`.
func loadNormalized(
    isolation: isolated (any Actor)? = #isolation, _ run: () async throws -> Double
) async rethrows -> Double {
    let probe = CPUShareProbe()
    defer { _ = probe.stop() }  // a throwing run must still end the spin thread; stop() is idempotent
    let wall = try await run()
    return wall * max(probe.stop(), 0.02)
}
