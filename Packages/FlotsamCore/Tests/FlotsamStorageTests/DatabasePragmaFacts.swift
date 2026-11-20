import Foundation
import GRDB
@testable import FlotsamStorage

/// What an open database reports about itself, read straight through `pool`. TASK-567 removed the production
/// `FlotsamDatabase.diagnostics()` (no app caller); the tests that asserted pragmas and schema version read them here.
struct DatabasePragmaFacts: Equatable {
    let journalMode: String
    let foreignKeysEnabled: Bool
    let secureDeleteEnabled: Bool
    let userVersion: Int
}

extension FlotsamDatabase {
    /// WAL, foreign_keys, secure_delete and user_version, read on a pool reader connection (the same connections
    /// the app reads on, so the per-connection pragmas are the ones the app actually runs with).
    func pragmaFacts() async throws -> DatabasePragmaFacts {
        try await pool.read { db in
            DatabasePragmaFacts(
                journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
                foreignKeysEnabled: try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1,
                secureDeleteEnabled: try Int.fetchOne(db, sql: "PRAGMA secure_delete") == 1,
                userVersion: try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0)
        }
    }
}
