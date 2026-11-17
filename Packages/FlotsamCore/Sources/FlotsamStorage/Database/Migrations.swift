import FlotsamBase
import GRDB

/// One forward-only migration. `version` is the value of `PRAGMA user_version` after it applies.
struct Migration {
    let version: Int
    let apply: @Sendable (Database) throws -> Void
}

/// All migrations, in order. Migration 1 is the skeleton `meta` table; the item schema (FRD-007 FR-007-03,
/// sketched in docs/ARCHITECTURE.md) arrives with the FRD-007 build ticket as migration 2.
enum Migrations {
    static let all: [Migration] = [
        Migration(version: 1) { db in
            try db.execute(sql: """
                CREATE TABLE meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                ) WITHOUT ROWID
                """)
        },
    ]
}

/// Runs migrations under `PRAGMA user_version` (FR-007-17, ADR-0002). Each migration and its version bump share
/// one transaction. Before the first pending migration on an existing database, `beforeMigrating` is called so the
/// caller can take the pre-migration copy.
enum MigrationRunner {
    static func currentVersion(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }

    static func migrate(
        _ pool: DatabasePool,
        migrations: [Migration] = Migrations.all,
        beforeMigrating: (_ fromVersion: Int) -> FlotsamResult<Void>
    ) throws -> FlotsamResult<Void> {
        let current = try pool.read { try currentVersion($0) }
        let pending = migrations.filter { $0.version > current }.sorted { $0.version < $1.version }
        guard !pending.isEmpty else { return .success(()) }
        if current > 0, case .failure(let error) = beforeMigrating(current) { return .failure(error) }
        for migration in pending {
            try pool.write { db in
                try migration.apply(db)
                try db.execute(sql: "PRAGMA user_version = \(migration.version)")
            }
        }
        return .success(())
    }
}
