import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-501 AC1. `FlotsamDatabase.open` is async but every step of it is synchronous, and SQLite's busy handler blocks the
// calling thread for up to the busy timeout while another connection holds the file. Run on a cooperative-pool thread
// that parks the thread; as many such opens as the pool has threads leave every other `await` in the process waiting.
//
// The test holds as many locks as the pool is wide, starts one open behind each, and then asks the pool for one more
// thing: an `await Task.sleep`. If the opens held pool threads the sleep cannot resume until a lock is gone, so the
// thread-of-its-own watchdog below, which only lets go of the locks after 15 s, is what ends the wait and the test reads
// "locks released" at the moment its own sleep returns. Nothing here depends on how fast the machine is: the opens are
// kept waiting by the locks, not by a timer the test has to win.

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    /// True for the one caller that sets it.
    func setOnce() -> Bool { lock.withLock { defer { value = true }; return !value } }
}

@Suite("TASK-501 open waits on a lock without holding a pool thread", .serialized)
struct Task501OpenOffPoolTests {
    private func holdExclusiveLock(_ root: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { db in _ = try String.fetchOne(db, sql: "PRAGMA locking_mode = EXCLUSIVE") }
        let queue = try DatabaseQueue(path: root.appendingPathComponent(FlotsamDatabase.fileName).path, configuration: configuration)
        try queue.inDatabase { db in _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") }
        return queue
    }

    /// Given one open waiting on a lock for every thread of the cooperative pool, when the test awaits a 0.5 s sleep, then
    /// the sleep returns while every lock is still held, and every open succeeds once the locks are gone. Red if `open`
    /// runs its blocking steps on the caller's thread: the sleep cannot resume until the watchdog frees the locks.
    @Test("opens waiting on locks leave the cooperative pool free")
    func opensWaitingOnLocksLeaveThePoolFree() async throws {
        let width = ProcessInfo.processInfo.activeProcessorCount + 2
        var roots: [URL] = []
        var holders: [DatabaseQueue] = []
        defer { for root in roots { try? FileManager.default.removeItem(at: root) } }
        for _ in 0..<width {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("task501-\(UUID().uuidString)")
            roots.append(root)
            _ = try await FlotsamDatabase.openBaseline(folder: root).get()
            holders.append(try holdExclusiveLock(root))
        }

        let released = Flag()
        let locks = holders
        let releaseAll: @Sendable () -> Void = {
            guard released.setOnce() else { return }
            for holder in locks { try? holder.close() }
        }
        // A thread of its own, so a wedged pool cannot also keep the watchdog from running (TASK-496, ReleaseAfter.swift).
        releaseAfter(15, releaseAll)

        let opens = roots.map { root in
            Task {
                await FlotsamDatabase.open(
                    folder: root, fileSystem: LocalFileSystem(), migrations: Migrations.baseline, busyTimeout: 60)
            }
        }

        try await Task.sleep(for: .milliseconds(500))
        let lockWasStillHeld = !released.isSet
        releaseAll()

        var failures: [FlotsamError] = []
        for open in opens {
            if case .failure(let error) = await open.value { failures.append(error) }
        }
        #expect(lockWasStillHeld, "the pool was blocked by the waiting opens: a 0.5 s sleep did not return until the locks were freed")
        #expect(failures.isEmpty, "every open succeeds once its lock is gone: \(failures)")
    }
}
