import FlotsamBase
import Foundation
import GRDB

/// The ranges offered by Settings > Storage > Clear History (FR-007-11).
public enum ClearRange: Sendable, Equatable, CaseIterable {
    case lastHour, last24Hours, allTime

    /// How far back from now the range reaches; nil for all time.
    var lookbackMillis: Int64? {
        switch self {
        case .lastHour: 60 * 60 * 1000
        case .last24Hours: 24 * 60 * 60 * 1000
        case .allTime: nil
        }
    }
}

/// What a Clear History run did (FR-007-11).
public struct ClearOutcome: Sendable, Equatable {
    /// Items actually removed; the HUD announces "{n} items deleted" from this, not from the earlier preview, because
    /// the preview can be a few seconds old.
    public let deletedCount: Int
    /// False when readers kept `wal_checkpoint(TRUNCATE)` from finishing. The items are gone from the database
    /// either way; this tells the caller the WAL file was not yet truncated, so the on-disk scrub is incomplete.
    public let checkpointCompleted: Bool
}

extension DeletionPreview {
    /// Nothing would be deleted. For Clear History that means the Delete button is disabled with "Nothing to clear
    /// in this range." and no confirmation exists to show (FR-007-11, FR-007-09's zero rule).
    public var isEmpty: Bool { count == 0 }
}

extension FlotsamDatabase {
    private static let clearBatchSize = 500

    /// The one selection for Clear History, used by the preview and the delete so the count the user confirms is
    /// the count removed. Bounded on both sides: `lastCopiedAt` in `[now - lookback, startedAt]`. The upper bound
    /// matters: without it, items captured while the delete runs would be swept in and a busy clipboard could keep
    /// the loop alive.
    ///
    /// Exemption: without `includeExempt`, `Exemption.notExemptSQL` only. The 24 h release grace is not applied,
    /// because Clear History is the user's explicit, counted action (see FR-007-10).
    private static func clearSQL(range: ClearRange, includeExempt: Bool) -> String {
        var clauses = ["lastCopiedAt <= ?"]
        if range.lookbackMillis != nil { clauses.append("lastCopiedAt >= ?") }
        if !includeExempt { clauses.append(Exemption.notExemptSQL) }
        return clauses.joined(separator: " AND ")
    }

    private static func clearArguments(range: ClearRange, now: Int64) -> StatementArguments {
        range.lookbackMillis.map { [now, now - $0] } ?? [now]
    }

    /// What Clear History would delete right now, for the sheet's "Delete {n} Items" button. Deletes nothing.
    /// `isEmpty` means the UI disables Delete and shows "Nothing to clear in this range." (FR-007-11).
    public func clearHistoryPreview(range: ClearRange, includeExempt: Bool) async -> FlotsamResult<DeletionPreview> {
        let now = clock.now().epochMillis
        let selection = Self.clearSQL(range: range, includeExempt: includeExempt)
        let arguments = Self.clearArguments(range: range, now: now)
        do {
            return .success(try await pool.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) AS count,
                               COALESCE((SELECT SUM(byteSize) FROM representation WHERE itemId IN
                                   (SELECT id FROM item WHERE \(selection))), 0) AS bytes
                        FROM item WHERE \(selection)
                        """,
                    arguments: arguments + arguments)
                return DeletionPreview(count: row?["count"] ?? 0, bytes: row?["bytes"] ?? 0)
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }

    /// Clear History (FR-007-11): deletes every item whose `lastCopiedAt` is in `range` through `delete(ids:)`
    /// (FR-007-15), in batches of 500 so the writer is never held long. Tags are kept (`itemTag` rows go by cascade,
    /// `tag` rows are never touched), `screenshots.lastScanAt` is not reset so cleared screenshots are not
    /// re-imported, and files held by reference and screenshot originals are never read, as in every deletion.
    ///
    /// Afterwards the database is scrubbed: `incremental_vacuum` returns the freed pages to the file system, then
    /// `wal_checkpoint(TRUNCATE)` folds the write-ahead log in and empties it. With `secure_delete` on (FR-007-02) the
    /// freed pages were already overwritten, so the deleted content is not left in `flotsam.sqlite` or its WAL. The
    /// checkpoint runs last because the vacuum itself writes through the WAL.
    ///
    /// `progress(deleted, total)` is called after each batch so the UI can show a progress state once the work passes
    /// one second. Zero matching items does nothing (no scrub, no work): there is nothing to confirm either.
    public func clearHistory(
        range: ClearRange, includeExempt: Bool, progress: (@Sendable (_ deleted: Int, _ total: Int) -> Void)? = nil
    ) async -> FlotsamResult<ClearOutcome> {
        // One `clearHistory` interval spans the count, every delete batch and the scrub, because FR-007-16's 5 s budget
        // is for the whole operation the user waits on, not for one step of it.
        await FlotsamSignpost.measure("clearHistory") { () async -> FlotsamResult<ClearOutcome> in
            await performClearHistory(range: range, includeExempt: includeExempt, progress: progress)
        }
    }

    private func performClearHistory(
        range: ClearRange, includeExempt: Bool, progress: (@Sendable (_ deleted: Int, _ total: Int) -> Void)?
    ) async -> FlotsamResult<ClearOutcome> {
        let startedAt = clock.now().epochMillis
        let selection = Self.clearSQL(range: range, includeExempt: includeExempt)
        let arguments = Self.clearArguments(range: range, now: startedAt)

        let total: Int
        do {
            total = try await pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE \(selection)", arguments: arguments) ?? 0
            }
        } catch {
            return .failure(Self.readFailure(error))
        }
        guard total > 0 else { return .success(ClearOutcome(deletedCount: 0, checkpointCompleted: true)) }

        var deleted = 0
        batches: while true {
            let ids: [UUID]
            do {
                ids = try await pool.read { db in
                    try String.fetchAll(
                        db,
                        sql: "SELECT id FROM item WHERE \(selection) ORDER BY lastCopiedAt ASC, id ASC LIMIT ?",
                        arguments: arguments + [Self.clearBatchSize]
                    ).compactMap(UUID.init(uuidString:))
                }
            } catch {
                return .failure(Self.readFailure(error))
            }
            guard !ids.isEmpty else { break batches }
            switch await delete(ids: ids) {
            case .failure(let error): return .failure(error)
            case .success(let removed):
                deleted += removed.count
                progress?(deleted, total)
                // Nothing removed means the rows vanished under us; looping again would only re-read them. The label
                // matters: a bare `break` would only leave this `switch`.
                if removed.isEmpty { break batches }
            }
        }
        if deleted > 0 {
            FlotsamLog.log(
                FlotsamError(.stoPol001, "Clear history", context: [.count: .int(deleted)]), category: .storage)
        }
        return .success(ClearOutcome(deletedCount: deleted, checkpointCompleted: await scrubDatabaseFile()))
    }

    /// True when the WAL was fully checkpointed and truncated. A failure here must not fail the Clear: the rows are
    /// already committed and deleted; it is reported through `ClearOutcome.checkpointCompleted` instead.
    private func scrubDatabaseFile() async -> Bool {
        do {
            return try await pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA incremental_vacuum")
                // Columns: busy (1 when readers blocked it), log frames, checkpointed frames.
                let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                return (row?[0] as Int64?) == 0
            }
        } catch {
            return false
        }
    }
}
