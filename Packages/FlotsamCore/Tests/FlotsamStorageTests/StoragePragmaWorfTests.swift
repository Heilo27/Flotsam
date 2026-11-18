import Foundation
import GRDB
import Testing
import FlotsamBase
@testable import FlotsamStorage

@Suite struct StoragePragmaWorfTests {
    /// FR-007-02 / TASK-045. Given a fresh data folder, when the database opens, then every connection     /// pooled reader) runs synchronous NORMAL (1) and a 5000 ms writer busy timeout.
    /// Red if the `PRAGMA synchronous = NORMAL` line in `FlotsamDatabase.configuration()` is deleted (SQLite default is
    /// FULL = 2) or the `busyMode = .timeout(...)` is removed or changed from 5 s (default 0).
    @Test("FR-007-02 the opened database runs synchronous NORMAL and a 5000 ms writer busy timeout")
    func synchronousNormalAndBusyTimeout() async throws {
        // given a data folder that does not exist yet
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-pragma-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        // when the database opens and both connection kinds are asked for their pragmas
        let database = try await FlotsamDatabase.open(folder: folder).get()
        let reader = try await database.pool.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA synchronous"), try Int.fetchOne(db, sql: "PRAGMA busy_timeout"))
        }
        let writer = try await database.pool.write { db in
            (try Int.fetchOne(db, sql: "PRAGMA synchronous"), try Int.fetchOne(db, sql: "PRAGMA busy_timeout"))
        }

        // then NORMAL (1, not the FULL default 2) is in force on both and the writer's busy timeout is 5000 ms (not the 0 default)
        #expect(reader.0 == 1)
        // (GRDB installs its own 10 s busy handler on pooled readers, so the configured 5 s is asserted on the writer.)
        #expect(writer.0 == 1)
        #expect(writer.1 == 5000)
    }
}
