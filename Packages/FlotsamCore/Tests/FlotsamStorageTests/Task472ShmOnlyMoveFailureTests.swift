import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-472 / FR-007-13, AC-007-11: when a quarantine fails partway (only the -shm cannot move) the launch fails
// closed (STO-DB-003) with the -wal already safe in corrupt-<ms>/. The relaunch recovers, and must still tell the
// user their library was quarantined: STO-DB-002, once, not on the launch after that.
@Suite("TASK-472: -shm-only quarantine failure still surfaces STO-DB-002 on relaunch", .timeLimit(.minutes(2)))
struct Task472ShmOnlyMoveFailureTests {
    private func open(_ root: URL, fs: any FileSystemPort = LocalFileSystem()) async -> (FlotsamError?, FlotsamError?) {
        switch await FlotsamDatabase.open(folder: root, fileSystem: fs, clock: SystemClock(), migrations: Migrations.all) {
        case .failure(let error): return (error, nil)
        case .success(let db): return (nil, db.openNotice)
        }
    }

    @Test func shmOnlyMoveFailure_relaunchRaisesNoticeOnce() async throws {
        let root = V370.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try V370.buildWithWal(into: root)
        let walSha = try #require(V370.sha(V370.walURL(root)))
        try Data().write(to: V370.dbURL(root))
        try Data("shm".utf8).write(to: root.appendingPathComponent("flotsam.sqlite-shm"))
        let fs = Worf380FileSystem()
        fs.failMoveNamed = ["flotsam.sqlite-shm"]

        let first = await open(root, fs: fs)
        #expect(first.0?.code == .stoDb003)

        let second = await open(root)
        #expect(second.0 == nil)
        #expect(second.1?.code == .stoDb002, "the relaunch must tell the user the library was quarantined")

        let third = await open(root)
        #expect(third.0 == nil)
        #expect(third.1 == nil, "the notice is raised once")

        let held = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?
            .filter { V370.sha(root.appendingPathComponent($0)) == walSha } ?? []
        #expect(held.count == 1 && held[0].hasPrefix("corrupt-"), "the -wal stays preserved in the quarantine, got \(held)")
    }
}
