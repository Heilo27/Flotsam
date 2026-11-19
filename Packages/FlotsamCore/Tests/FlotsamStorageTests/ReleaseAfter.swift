import Foundation

/// Runs `work` once, `seconds` from now, on a thread of its own.
///
/// WHY (TASK-496): the busy-open tests hold a lock and release it a fixed time later while the open under test waits it
/// out (SQLite's busy handler blocks its thread). Releasing through `DispatchQueue.global().asyncAfter` made the release
/// ride the shared GCD pool, which the rest of the parallel run keeps full of blocked workers: a release due at 0.4 s or
/// 2 s ran 2 to 9 s late (measured, 12 loaded runs), often past the open's 5 s timeout, so a correct open reported
/// STO-DB-003. A thread of its own does not queue behind them.
func releaseAfter(_ seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) {
    let thread = Thread {
        Thread.sleep(forTimeInterval: seconds)
        work()
    }
    thread.start()
}
