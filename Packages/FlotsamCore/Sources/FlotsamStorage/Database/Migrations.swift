import FlotsamBase
import GRDB

/// One forward-only migration. `version` is the value of `PRAGMA user_version` after it applies.
struct Migration {
    let version: Int
    let apply: @Sendable (Database) throws -> Void
}

/// All migrations, in order. Version 1 is the FR-007-03 schema; version 2 adds secure clips (`Schema.createVersion2`); version 3 adds the bundle name (`Schema.createVersion3`); version 4 adds recognised image text (`Schema.createVersion4`); version 5 adds the search text an MCP client may match (`Schema.createVersion5`).
/// A later release appends; it never edits an earlier entry.
enum Migrations {
    static let all: [Migration] = [
        Migration(version: 1, apply: Schema.createVersion1),
        Migration(version: 2, apply: Schema.createVersion2),
        Migration(version: 3, apply: Schema.createVersion3),
        Migration(version: 4, apply: Schema.createVersion4),
        Migration(version: 5, apply: Schema.createVersion5),
    ]

    /// The newest version this build understands. A database above it came from a newer app (FR-007-17).
    static func newestVersion(in migrations: [Migration]) -> Int { migrations.map(\.version).max() ?? 0 }
}

/// Runs migrations under `PRAGMA user_version` (FR-007-17, ADR-0002). Each migration, its version bump and the
/// `meta.schemaVersion` mirror share one transaction, so a failure leaves the previous version intact.
enum MigrationRunner {
    static func currentVersion(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }

    /// `beforeMigrating` runs once, before the first pending migration, with the version being left. The caller
    /// decides whether a copy is warranted (it knows whether the file existed before this launch).
    static func migrate(
        _ pool: DatabasePool,
        migrations: [Migration] = Migrations.all,
        beforeMigrating: (_ fromVersion: Int) -> FlotsamResult<Void>
    ) throws -> FlotsamResult<Void> {
        let current = try pool.read { try currentVersion($0) }
        let pending = migrations.filter { $0.version > current }.sorted { $0.version < $1.version }
        guard !pending.isEmpty else { return .success(()) }
        if case .failure(let error) = beforeMigrating(current) { return .failure(error) }
        for migration in pending {
            try pool.write { db in
                try migration.apply(db)
                try db.execute(sql: "PRAGMA user_version = \(migration.version)")
                try db.execute(
                    sql: "INSERT INTO meta(key, value) VALUES ('schemaVersion', ?) "
                        + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [String(migration.version)])
            }
        }
        return .success(())
    }
}
