import GRDB

/// Keys of the `meta` table that are not the schema version (FR-007-03).
enum MetaKey {
    static let screenshotsLastScanAt = "screenshots.lastScanAt"
    static let retentionLastSweepAt = "retention.lastSweepAt"
    static let budgetLastNoticeAt = "budget.lastNoticeAt"
}

/// The only reader and writer of integer `meta` values, so the string encoding lives in one place.
enum MetaStore {
    static func int64(_ db: Database, _ key: String) throws -> Int64? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]).flatMap { Int64($0) }
    }

    static func setInt64(_ db: Database, _ key: String, _ value: Int64) throws {
        try db.execute(
            sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key, String(value)])
    }

    /// Monotone write: the stored value becomes the larger of itself and `value`, decided inside the statement, so
    /// the outcome never depends on the order two writes arrive in. `value` is TEXT, so both sides are cast to
    /// integers first; a text `max` would order "9999" above "10000". Only for values that must never go backwards
    /// (the screenshot watermark, FR-002-08); a caller that legitimately overwrites uses `setInt64`.
    static func raiseInt64(_ db: Database, _ key: String, to value: Int64) throws {
        try db.execute(
            sql: """
                INSERT INTO meta(key, value) VALUES(?, ?)
                ON CONFLICT(key) DO UPDATE SET value = max(CAST(value AS INTEGER), CAST(excluded.value AS INTEGER))
                """,
            arguments: [key, String(value)])
    }
}
