import FlotsamBase
import Foundation
import GRDB

/// Facts about an open database, used by tests and the diagnostics report.
public struct StorageDiagnostics: Sendable, Equatable {
    public let journalMode: String
    public let foreignKeysEnabled: Bool
    public let secureDeleteEnabled: Bool
    public let userVersion: Int
}

/// The database. Only this module imports GRDB (ADR-0001). Every function is `async` and returns `Result`;
/// there is no synchronous read, so a main-thread read cannot be written (ADR-0004).
public final class FlotsamDatabase: Sendable {
    public static let fileName = "flotsam.sqlite"
    public static let preMigrationFolderName = "pre-migration"
    public static let folderPermissions = 0o700
    private static let busyTimeoutSeconds = 5.0
    private static let sqliteDomain = "GRDB.DatabaseError"

    private let pool: DatabasePool

    private init(pool: DatabasePool) { self.pool = pool }

    /// Creates the data folder (0700), opens the pool with the FR-007-01 pragmas and migrates.
    /// Folder failure is `STO-IO-002`; any database failure is `STO-DB-003` (both Fatal, FR-000-04).
    public static func open(
        folder: URL, fileSystem: any FileSystemPort = LocalFileSystem()
    ) async -> FlotsamResult<FlotsamDatabase> {
        await open(folder: folder, fileSystem: fileSystem, migrations: Migrations.all)
    }

    /// Internal so tests can simulate a later release's migrations against an existing file.
    static func open(
        folder: URL, fileSystem: any FileSystemPort, migrations: [Migration]
    ) async -> FlotsamResult<FlotsamDatabase> {
        if case .failure = fileSystem.createDirectory(at: folder, permissions: folderPermissions) {
            return .failure(FlotsamError(.stoIo002, "Data folder could not be created"))
        }
        do {
            let pool = try DatabasePool(
                path: folder.appendingPathComponent(fileName).path, configuration: configuration())
            let backupFolder = folder.appendingPathComponent(preMigrationFolderName)
            let migrated = try MigrationRunner.migrate(pool, migrations: migrations) { fromVersion in
                preMigrationCopy(
                    pool: pool, folder: folder, backupFolder: backupFolder, fromVersion: fromVersion,
                    fileSystem: fileSystem)
            }
            if case .failure(let error) = migrated { return .failure(error) }
            return .success(FlotsamDatabase(pool: pool))
        } catch {
            return .failure(mapped(error))
        }
    }

    public func diagnostics() async -> FlotsamResult<StorageDiagnostics> {
        do {
            return .success(try await pool.read { db in
                StorageDiagnostics(
                    journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
                    foreignKeysEnabled: try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1,
                    secureDeleteEnabled: try Int.fetchOne(db, sql: "PRAGMA secure_delete") == 1,
                    userVersion: try MigrationRunner.currentVersion(db))
            })
        } catch {
            return .failure(Self.mapped(error))
        }
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(busyTimeoutSeconds)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return configuration
    }

    /// FR-007-17: copy the database file aside before migrating an existing one.
    private static func preMigrationCopy(
        pool: DatabasePool, folder: URL, backupFolder: URL, fromVersion: Int, fileSystem: any FileSystemPort
    ) -> FlotsamResult<Void> {
        do {
            try pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        } catch {
            return .failure(mapped(error))
        }
        if case .failure = fileSystem.createDirectory(at: backupFolder, permissions: folderPermissions) {
            return .failure(FlotsamError(.stoDb003, "Pre-migration folder could not be created"))
        }
        let destination = backupFolder.appendingPathComponent("v\(fromVersion)-\(fileName)")
        let copied = fileSystem.copyItem(at: folder.appendingPathComponent(fileName), to: destination)
        if case .failure = copied { return .failure(FlotsamError(.stoDb003, "Pre-migration copy failed")) }
        return .success(())
    }

    private static func mapped(_ error: Error) -> FlotsamError {
        let nsError = error as NSError
        let resultCode = (error as? DatabaseError).map { Int($0.extendedResultCode.rawValue) } ?? nsError.code
        return FlotsamError(
            .stoDb003, "Database could not be opened or migrated",
            underlying: UnderlyingErrorInfo(domain: sqliteDomain, code: resultCode))
    }
}
