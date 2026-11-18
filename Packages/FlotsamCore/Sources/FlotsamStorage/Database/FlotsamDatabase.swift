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
    /// Where this database's log records go (FR-000-09). The production sink writes to `os.Logger`; a test injects a
    /// recording one, because `os.Logger` has no readback that shows the redacted (`.private`) parts of a line.
    let logSink: any LogSink

    private init(
        pool: DatabasePool, folder: DataFolder, fileSystem: any FileSystemPort, clock: any WallClock,
        notice: FlotsamError?, logSink: any LogSink
    ) {
        self.pool = pool
        self.folder = folder
        self.fileSystem = fileSystem
        self.clock = clock
        self.openNotice = notice
        self.logSink = logSink
    }

    /// The one way Storage logs an error: category `storage`, through this database's sink (FR-000-09, FR-000-10).
    func report(_ error: FlotsamError) {
        FlotsamLog.log(error, category: .storage, sink: logSink)
    }

    /// Blob files for this database's folder (FR-007-04). A value built on demand: it holds no state of its own.
    var blobs: BlobStore { BlobStore(folder: folder, fileSystem: fileSystem) }

    /// Creates the data folder (0700), opens the pool with the FR-007-02 pragmas, migrates and integrity-checks.
    /// Folder failure is `STO-IO-002`; any other database failure is `STO-DB-003` (both Fatal, FR-000-04).
    public static func open(
        folder: URL, fileSystem: any FileSystemPort = LocalFileSystem(), clock: any WallClock = SystemClock(),
        logSink: any LogSink = OSLogSink()
    ) async -> FlotsamResult<FlotsamDatabase> {
        await open(folder: folder, fileSystem: fileSystem, clock: clock, logSink: logSink, migrations: Migrations.all)
    }

    private enum Attempt {
        /// `migratedThisLaunch`: a migration ran (or the file was new) in this very launch (FR-007-17 expiry).
        case opened(DatabasePool, migratedThisLaunch: Bool)
        case damaged
        case failed(FlotsamError)
    }

    /// Internal so tests can simulate a later release's migrations against an existing file.
    static func open(
        folder root: URL, fileSystem: any FileSystemPort, clock: any WallClock = SystemClock(),
        logSink: any LogSink = OSLogSink(), migrations: [Migration]
    ) async -> FlotsamResult<FlotsamDatabase> {
        let layout = DataFolder(root: root)
        if case .failure(let error) = layout.prepare(fileSystem: fileSystem) { return .failure(error) }

        var notice: FlotsamError?
        // Two attempts: the second runs only after a damaged file was moved aside (FR-007-13). A fresh file that is
        // itself reported damaged is a real fault, not something another quarantine can fix.
        for attemptNumber in 0..<2 {
            switch attempt(layout: layout, fileSystem: fileSystem, migrations: migrations, sink: logSink) {
            case .opened(let pool, let migratedThisLaunch):
                // FR-007-17 / FR-007-13: a clean open on a launch that did not migrate ends the life of old plaintext copies.
                if !migratedThisLaunch { layout.expirePlaintextCopies(fileSystem: fileSystem, now: clock.now()) }
                FlotsamLog.log(.database(.open, outcome: .opened), sink: logSink)
                return .success(FlotsamDatabase(pool: pool, folder: layout, fileSystem: fileSystem, clock: clock, notice: notice, logSink: logSink))
            case .failed(let error):
                FlotsamLog.log(.database(.open, outcome: .failed), sink: logSink)
                return .failure(error)
            case .damaged:
                guard attemptNumber == 0, quarantine(layout: layout, fileSystem: fileSystem) else {
                    FlotsamLog.log(.database(.open, outcome: .failed), sink: logSink)
                    return .failure(FlotsamError(.stoDb003, "Database damaged and could not be set aside"))
                }
                notice = FlotsamError(.stoDb002, "Database damaged; moved aside and recreated")
            }
        }
        FlotsamLog.log(.database(.open, outcome: .failed), sink: logSink)
        return .failure(FlotsamError(.stoDb003, "Database could not be opened"))
    }

    // MARK: Opening

    /// Logs the FR-000-11 `database.*` steps as they happen: the integrity check on an existing file, the migration when
    /// one ran, and the post-migration integrity check. Outcomes only; no path and no row content.
    private static func attempt(
        layout: DataFolder, fileSystem: any FileSystemPort, migrations: [Migration], sink: any LogSink
    ) -> Attempt {
        let existed = (fileSystem.fileInfo(at: layout.databaseURL)?.byteSize ?? 0) > 0
        // WHY: SQLite deletes the `-wal` of a zero-byte main file when it opens one (an empty database cannot have a
        // WAL, so it discards it). Committed frames would then exist nowhere, so the pair is damage and is set aside
        // before any open (FR-007-13). No integrity check ran on it; the failed entry is how the log records damage.
        if !existed, (fileSystem.fileInfo(at: layout.walURL)?.byteSize ?? 0) > 0 {
            FlotsamLog.log(.database(.integrityCheck, outcome: .failed), sink: sink)
            return .damaged
        }
        do {
            if existed {
                // A read-only probe comes first and runs the integrity check (FR-007-13), so a newer-version or damaged
                // database is refused or quarantined while still byte-identical: opening the pool would switch the
                // journal mode, rewrite the header and VACUUM (AC-007-15).
                let probed = try probe(layout: layout, fileSystem: fileSystem)
                if case .damaged = probed {
                    FlotsamLog.log(.database(.integrityCheck, outcome: .failed), sink: sink)
                } else {
                    FlotsamLog.log(.database(.integrityCheck, outcome: .passed), sink: sink)
                }
                switch probed {
                case .damaged: return .damaged
                case .version(let version) where version > Migrations.newestVersion(in: migrations):
                    return .failed(FlotsamError(.stoDb003, "Database was written by a newer version"))
                case .version: break
                }
            }
            if case .failure(let error) = layout.prepareDatabaseFiles(fileSystem: fileSystem) { return .failed(error) }
            let pool = try DatabasePool(path: layout.databaseURL.path, configuration: configuration())
            let versionBefore = try pool.read { try MigrationRunner.currentVersion($0) }
            try ensureIncrementalVacuum(pool)
            let migrated = try MigrationRunner.migrate(pool, migrations: migrations) { fromVersion in
                existed
                    ? preMigrationCopy(pool: pool, layout: layout, fromVersion: fromVersion, fileSystem: fileSystem)
                    : .success(())
            }
            if case .failure(let error) = migrated {
                FlotsamLog.log(.database(.migrate, outcome: .failed), sink: sink)
                return .failed(error)
            }
            // WHY: the second check verifies the migrated file. The probe already vouched for the file as found, so a
            // failure here is a migration bug (or the open itself writing a bad file), not user damage. It still takes
            // the damaged path, because a database that fails its integrity check must not stay live, but the file has
            // been written to by now: that quarantined copy is not the bytes the user had.
            let versionAfter = try pool.read { try MigrationRunner.currentVersion($0) }
            if versionAfter != versionBefore { FlotsamLog.log(.database(.migrate, outcome: .migrated), sink: sink) }
            let passed = try pool.read { try integrityCheckPasses($0) }
            FlotsamLog.log(.database(.integrityCheck, outcome: passed ? .passed : .failed), sink: sink)
            return passed ? .opened(pool, migratedThisLaunch: versionAfter != versionBefore) : .damaged
        } catch {
            return isDamage(error) ? .damaged : .failed(mapped(error))
        }
    }

    private enum Probe { case version(Int), damaged }

    private static func probe(layout: DataFolder, fileSystem: any FileSystemPort) throws -> Probe {
        do {
            return try probeFile(at: layout.databaseURL, readonly: true)
        } catch {
            if isDamage(error) { return .damaged }
            // WHY: a read-only connection cannot open a WAL-mode file that has no `-shm` beside it (SQLITE_CANTOPEN),
            // which is the normal state after a clean shutdown or when the file was copied alone. The healthy file
            // must still open, and the damaged one must still be quarantined untouched, so the check moves to a
            // private copy and the user's file is never written to.
            guard isCannotOpen(error) else { throw error }
            return try probeCopy(of: layout, fileSystem: fileSystem, original: error)
        }
    }

    private static func probeFile(at url: URL, readonly: Bool) throws -> Probe {
        var configuration = Configuration()
        configuration.readonly = readonly
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            // `quick_check` runs before the version is trusted: a damaged file can report any user_version.
            try integrityCheckPasses(db) ? .version(try MigrationRunner.currentVersion(db)) : .damaged
        }
    }

    /// Runs the probe on a copy of the main file and its `-wal` (the committed state SQLite would read) in
    /// `tmp/probe-<uuid>/`, inside the data folder (FR-007-01) and removed afterwards. SQLite may create `-shm` and
    /// checkpoint there; the original is only ever read. A copy that cannot be made rethrows the original error.
    private static func probeCopy(of layout: DataFolder, fileSystem: any FileSystemPort, original: Error) throws -> Probe {
        let scratch = layout.tmpURL.appendingPathComponent("probe-\(UUID().uuidString)")
        guard case .success = fileSystem.createDirectory(at: scratch, permissions: DataFolder.folderPermissions) else {
            throw original
        }
        defer { _ = fileSystem.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent(FlotsamDatabase.fileName)
        let sources = [layout.databaseURL, layout.walURL]
        for source in sources where fileSystem.fileExists(at: source) {
            let target = scratch.appendingPathComponent(source.lastPathComponent)
            guard case .success = fileSystem.copyItem(at: source, to: target) else { throw original }
        }
        do {
            return try probeFile(at: copy, readonly: false)
        } catch {
            if isDamage(error) { return .damaged }
            throw error
        }
    }

    /// The one integrity check (FR-007-13). It runs on the read-only probe of an existing file, before any write, to
    /// decide quarantine, and on every open after migration, to verify the migrated file.
    private static func integrityCheckPasses(_ db: Database) throws -> Bool {
        try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"]
    }

    private static func isCannotOpen(_ error: Error) -> Bool {
        (error as? DatabaseError)?.resultCode == .SQLITE_CANTOPEN
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

    /// Moves `flotsam.sqlite*` and `blobs/` into `corrupt-<timestamp>/` (FR-007-13). Nothing here deletes them: they are
    /// kept for recovery until the window in `DataFolder.quarantineRetentionMillis` passes or Clear History runs.
    private static func quarantine(layout: DataFolder, fileSystem: any FileSystemPort) -> Bool {
        let stamp = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let destination = layout.quarantineURL(stamp: stamp)
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

    /// FR-007-17: copy the database aside before migrating an existing one, keeping only the latest copy. Pruning is
    /// limited to regular files Flotsam created (`DataFolder.preMigrationCopyInfo`); the folder is user-visible, so any other
    /// file in it is left alone. Stale `-wal`/`-shm` files beside the new copy's name are pruned too, because SQLite
    /// would replay them into the fresh copy when it is opened.
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
        // A regular file on the name is a stale copy: replaced. Anything else (a folder, a link) is the user's: never
        // deleted, never an error; the copy goes under the next free `flotsam-v<from>-<n>.sqlite` instead, a name the
        // prune and the purge still recognise.
        var name = DataFolder.preMigrationCopyName(fromVersion: fromVersion)
        var alternate = 0
        while let occupant = fileSystem.fileInfo(at: backupFolder.appendingPathComponent(name)), occupant.kind != .regular {
            alternate += 1
            name = DataFolder.preMigrationCopyName(fromVersion: fromVersion, alternate: alternate)
        }
        let destination = backupFolder.appendingPathComponent(name)
        if fileSystem.fileExists(at: destination) { _ = fileSystem.removeItem(at: destination) }
        guard case .success = fileSystem.copyItem(at: layout.databaseURL, to: destination) else {
            return .failure(FlotsamError(.stoDb003, "Pre-migration copy failed"))
        }
        if case .success(let others) = fileSystem.contentsOfDirectory(at: backupFolder) {
            for url in others
            where url.lastPathComponent != name
                && DataFolder.preMigrationCopyInfo(at: url, fileSystem: fileSystem) != nil {
                _ = fileSystem.removeItem(at: url)
            }
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
