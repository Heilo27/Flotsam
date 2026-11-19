import FlotsamBase
import Foundation
import GRDB

/// The three figures Settings > Storage shows as read-only labels (FRD-007 section 8, "Storage usage"). The core returns
/// numbers only; formatting them as "12.4 MB" is the UI layer's job (FRD-008).
public struct StorageUsage: Sendable, Equatable {
    /// Every item in the library, whatever its kind or state: the same count the Library shows under the "All" filter.
    public let totalItems: Int
    /// Stored bytes of image and screenshot representations: the figure the image budget is measured against
    /// (FR-007-08), so the label and the limit can never disagree. Thumbnails are not counted.
    public let imageBytes: Int64
    /// Size of the database as SQLite sees it (`page_count * page_size`), not the size of `flotsam.sqlite` on disk.
    public let databaseBytes: Int64
}

extension FlotsamDatabase {
    /// Current storage usage, read in one transaction so the three figures describe the same moment. The UI calls this
    /// each time Settings > Storage opens ("refreshed on open"), so it never caches.
    ///
    /// The database size comes from the page counters, not from the file's length, because the database runs in WAL
    /// mode: a handful of new rows land in `flotsam.sqlite-wal` and leave the main file's length unchanged until the
    /// next checkpoint, so a file-size label would not grow after copying (OC-7151). The page counters include pages
    /// still in the WAL, and fall after Clear History's `incremental_vacuum` returns pages to the file system.
    ///
    /// Failure is `STO-DB-004`, as for every read (FR-007-18).
    public func storageUsage() async -> FlotsamResult<StorageUsage> {
        do {
            return .success(try await pool.read { db in
                StorageUsage(
                    // Storage accounting counts every stored row, hidden or not: the space is used either way (FR-008-42).
                    totalItems: try Self.count(db, selection: Selection(filter: .all, text: "", ignoredApps: [])),
                    imageBytes: try Self.imageBytes(db),
                    databaseBytes: try Self.databaseBytes(db))
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }

    private static func databaseBytes(_ db: Database) throws -> Int64 {
        let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
        let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
        return pages * pageSize
    }
}
