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

/// The database and the services that share its lifetime. Only this module imports GRDB (ADR-0001). Every public
/// function is `async` and returns `Result`; there is no synchronous read, so a main-thread read cannot be written
/// (ADR-0004).
///
/// The event bus hangs off the database because it must be shared: one bus so a deletion reaches every subscriber
/// (FR-007-15). The image worker and thumbnail cache (FR-007-07) will join it for the same reason.
public final class FlotsamDatabase: Sendable {
    public static let fileName = "flotsam.sqlite"
    public static let preMigrationFolderName = "pre-migration"
    public static let folderPermissions = DataFolder.folderPermissions
    private static let busyTimeoutSeconds = 5.0
    private static let sqliteDomain = "GRDB.DatabaseError"

    let pool: DatabasePool
    let fileSystem: any FileSystemPort
    public let folder: DataFolder
    /// The one clock for ingest, sweep and clear (FR-007-03 stores UTC milliseconds); tests inject a manual one.
    let clock: any WallClock
    public let events = ItemEventBus()
    /// One image in flight for ingest and thumbnails together (FR-007-07, FR-007-16).
    let imageWorker = ImageWorker()
    let thumbnails = ThumbnailCache()
    /// `STO-DB-002` when this launch found the file damaged, moved it aside and started fresh (FR-007-13). The app
    /// raises it as a Notice; Storage cannot, it has no UI.
    public let openNotice: FlotsamError?

    private init(
        pool: DatabasePool, folder: DataFolder, fileSystem: any FileSystemPort, clock: any WallClock,
        notice: FlotsamError?
    ) {
        self.pool = pool
        self.folder = folder
        self.fileSystem = fileSystem
        self.clock = clock
        self.openNotice = notice
    }

    /// Blob files for this database's folder (FR-007-04). A value built on demand: it holds no state of its own.
    var blobs: BlobStore { BlobStore(folder: folder, fileSystem: fileSystem) }

    /// Creates the data folder (0700), opens the pool with the FR-007-02 pragmas, migrates and integrity-checks.
    /// Folder failure is `STO-IO-002`; any other database failure is `STO-DB-003` (both Fatal, FR-000-04).
    public static func open(
        folder: URL, fileSystem: any FileSystemPort = LocalFileSystem(), clock: any WallClock = SystemClock()
    ) async -> FlotsamResult<FlotsamDatabase> {
        await open(folder: folder, fileSystem: fileSystem, clock: clock, migrations: Migrations.all)
    }

    private enum Attempt {
        case opened(DatabasePool)
        case damaged
        case failed(FlotsamError)
    }

    /// Internal so tests can simulate a later release's migrations against an existing file.
    static func open(
        folder root: URL, fileSystem: any FileSystemPort, clock: any WallClock = SystemClock(), migrations: [Migration]
    ) async -> FlotsamResult<FlotsamDatabase> {
        let layout = DataFolder(root: root)
        if case .failure(let error) = layout.prepare(fileSystem: fileSystem) { return .failure(error) }

        var notice: FlotsamError?
        // Two attempts: the second runs only after a damaged file was moved aside (FR-007-13). A fresh file that is
        // itself reported damaged is a real fault, not something another quarantine can fix.
        for attemptNumber in 0..<2 {
            switch attempt(layout: layout, fileSystem: fileSystem, migrations: migrations) {
            case .opened(let pool):
                layout.restrictDatabaseFilePermissions()
                return .success(FlotsamDatabase(pool: pool, folder: layout, fileSystem: fileSystem, clock: clock, notice: notice))
            case .failed(let error):
                return .failure(error)
            case .damaged:
                guard attemptNumber == 0, quarantine(layout: layout, fileSystem: fileSystem) else {
                    return .failure(FlotsamError(.stoDb003, "Database damaged and could not be set aside"))
                }
                notice = FlotsamError(.stoDb002, "Database damaged; moved aside and recreated")
            }
        }
        return .failure(FlotsamError(.stoDb003, "Database could not be opened"))
    }

    // MARK: Opening

    private static func attempt(layout: DataFolder, fileSystem: any FileSystemPort, migrations: [Migration]) -> Attempt {
        let existed = (fileSystem.fileInfo(at: layout.databaseURL)?.byteSize ?? 0) > 0
        do {
            if existed {
                // A read-only probe comes first so a newer-version database is refused while still byte-identical:
                // opening the pool would switch the journal mode and rewrite the header (AC-007-15).
                switch try probe(layout.databaseURL) {
                case .damaged: return .damaged
                case .version(let version) where version > Migrations.newestVersion(in: migrations):
                    return .failed(FlotsamError(.stoDb003, "Database was written by a newer version"))
                case .version: break
                }
            }
            let pool = try DatabasePool(path: layout.databaseURL.path, configuration: configuration())
            try ensureIncrementalVacuum(pool)
            let migrated = try MigrationRunner.migrate(pool, migrations: migrations) { fromVersion in
                existed
                    ? preMigrationCopy(pool: pool, layout: layout, fromVersion: fromVersion, fileSystem: fileSystem)
                    : .success(())
            }
            if case .failure(let error) = migrated { return .failed(error) }
            let check = try pool.read { try String.fetchAll($0, sql: "PRAGMA quick_check") }
            return check == ["ok"] ? .opened(pool) : .damaged
        } catch {
            return isDamage(error) ? .damaged : .failed(mapped(error))
        }
    }

    private enum Probe { case version(Int), damaged }

    private static func probe(_ url: URL) throws -> Probe {
        var readOnly = Configuration()
        readOnly.readonly = true
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: readOnly)
            return .version(try queue.read { try MigrationRunner.currentVersion($0) })
        } catch {
            if isDamage(error) { return .damaged }
            throw error
        }
    }

    /// SQLite reports a non-database file as NOTADB and a broken one as CORRUPT. Both mean "quarantine".
    private static func isDamage(_ error: Error) -> Bool {
        guard let sqlite = error as? DatabaseError else { return false }
        return sqlite.resultCode == .SQLITE_NOTADB || sqlite.resultCode == .SQLITE_CORRUPT
    }

    /// `auto_vacuum = INCREMENTAL` is what lets Clear History return freed pages to the OS (FR-007-11). SQLite only
    /// honours the setting before the first table exists (or after a VACUUM), so it is applied here, ahead of the
    /// migrations, and the VACUUM is a no-op on a fresh file.
    private static func ensureIncrementalVacuum(_ pool: DatabasePool) throws {
        let mode = try pool.read { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") } ?? 0
        guard mode != 2 else { return }
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            try db.execute(sql: "VACUUM")
        }
    }

    // MARK: Damaged database

    /// Moves `flotsam.sqlite*` and `blobs/` into `corrupt-<timestamp>/` and never deletes them (FR-007-13).
    private static func quarantine(layout: DataFolder, fileSystem: any FileSystemPort) -> Bool {
        let stamp = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let destination = layout.root.appendingPathComponent("corrupt-\(stamp)")
        guard case .success = fileSystem.createDirectory(at: destination, permissions: DataFolder.folderPermissions)
        else { return false }
        for url in layout.databaseFileURLs + [layout.blobsURL] where fileSystem.fileExists(at: url) {
            guard case .success = fileSystem.moveItem(
                at: url, to: destination.appendingPathComponent(url.lastPathComponent))
            else { return false }
        }
        return layout.prepare(fileSystem: fileSystem).isSuccess
    }

    // MARK: Migration backup

    /// FR-007-17: copy the database aside before migrating an existing one, keeping only the latest copy.
    private static func preMigrationCopy(
        pool: DatabasePool, layout: DataFolder, fromVersion: Int, fileSystem: any FileSystemPort
    ) -> FlotsamResult<Void> {
        do {
            try pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        } catch {
            return .failure(mapped(error))
        }
        let backupFolder = layout.preMigrationURL
        if case .failure = fileSystem.createDirectory(at: backupFolder, permissions: DataFolder.folderPermissions) {
            return .failure(FlotsamError(.stoDb003, "Pre-migration folder could not be created"))
        }
        let name = "flotsam-v\(fromVersion).sqlite"
        let destination = backupFolder.appendingPathComponent(name)
        if fileSystem.fileExists(at: destination) { _ = fileSystem.removeItem(at: destination) }
        guard case .success = fileSystem.copyItem(at: layout.databaseURL, to: destination) else {
            return .failure(FlotsamError(.stoDb003, "Pre-migration copy failed"))
        }
        if case .success(let others) = fileSystem.contentsOfDirectory(at: backupFolder) {
            for url in others where url.lastPathComponent != name { _ = fileSystem.removeItem(at: url) }
        }
        return .success(())
    }

    // MARK: Diagnostics and error mapping

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
            return .failure(Self.readFailure(error))
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

    private static func underlying(_ error: Error) -> UnderlyingErrorInfo {
        let nsError = error as NSError
        let code = (error as? DatabaseError).map { Int($0.extendedResultCode.rawValue) } ?? nsError.code
        return UnderlyingErrorInfo(domain: sqliteDomain, code: code)
    }

    private static func mapped(_ error: Error) -> FlotsamError {
        FlotsamError(.stoDb003, "Database could not be opened or migrated", underlying: underlying(error))
    }

    /// A failed write transaction (rolled back, disk full, constraint): `STO-DB-001` (FR-007-15).
    static func writeFailure(_ error: Error) -> FlotsamError {
        FlotsamError(.stoDb001, "Database write failed", underlying: underlying(error))
    }

    /// A failed read: `STO-DB-004`, which Library shows as an inline Retry (FR-007-18).
    static func readFailure(_ error: Error) -> FlotsamError {
        FlotsamError(.stoDb004, "Database read failed", underlying: underlying(error))
    }
}

extension Result where Success == Void {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
