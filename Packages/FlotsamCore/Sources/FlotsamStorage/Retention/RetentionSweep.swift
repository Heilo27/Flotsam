import FlotsamBase
import Foundation
import GRDB

extension RetentionPreset {
    /// How long an item may go uncopied before the sweep may delete it; nil for Forever. The day counts live here,
    /// in Storage, because the sweep and its confirmation count are the only users (FR-007-09).
    var periodMillis: Int64? {
        let day: Int64 = 24 * 60 * 60 * 1000
        switch self {
        case .d7: return 7 * day
        case .d30: return 30 * day
        case .d90: return 90 * day
        case .y1: return 365 * day
        case .forever: return nil
        }
    }
}

/// What one sweep did (FR-007-09). Counts only: the sweep logs no content and raises no Notice of its own.
public struct SweepOutcome: Sendable, Equatable {
    public let retentionDeleted: Int
    public let budget: BudgetOutcome
}

extension FlotsamDatabase {
    /// Deletions per transaction, so the single writer is never held for long (FR-007-09: at most 500, about 50 ms).
    private static let sweepBatchSize = 500

    /// Eligible = deletable as far as exemption and its 24 h grace go (`Exemption.autoDeletableSQL`, FR-007-10) and
    /// `lastCopiedAt` older than the preset (so re-copying renews an item). One predicate for the sweep and its
    /// preview, so the count the user confirms is the count deleted. Placeholders: grace cutoff, then age cutoff.
    private static func eligibleSQL() -> String {
        "\(Exemption.autoDeletableSQL) AND lastCopiedAt < ?"
    }

    private func eligibleArguments(_ period: Int64) -> StatementArguments {
        let now = clock.now().epochMillis
        return [Exemption.graceCutoff(now: now), now - period]
    }

    /// What a sweep under `preset` would delete right now, for the shorter-preset confirmation (FR-007-09). Deletes
    /// nothing. Forever, or nothing eligible, returns `.none` and the caller applies the setting without asking.
    public func retentionPreview(_ preset: RetentionPreset) async -> FlotsamResult<DeletionPreview> {
        guard let period = preset.periodMillis else { return .success(.none) }
        let arguments = eligibleArguments(period)
        do {
            return .success(try await pool.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) AS count,
                               COALESCE((SELECT SUM(byteSize) FROM representation WHERE itemId IN
                                   (SELECT id FROM item WHERE \(Self.eligibleSQL()))), 0) AS bytes
                        FROM item WHERE \(Self.eligibleSQL())
                        """,
                    arguments: arguments + arguments)
                return DeletionPreview(count: row?["count"] ?? 0, bytes: row?["bytes"] ?? 0)
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
    }

    /// One retention sweep: time-based deletion for `preset`, then the image budget, which applies even under
    /// Forever (FR-007-09). The whole sweep is one `retention.sweep` signpost interval and each batch is an event
    /// inside it, so Instruments shows one bar with the batch cadence rather than many short bars.
    ///
    /// Items are re-selected per batch instead of listing every eligible id up front: memory stays bounded and a
    /// batch never works from a stale list if the user pins something mid-sweep.
    public func runRetentionSweep(preset: RetentionPreset, budget: ImageBudget) async -> FlotsamResult<SweepOutcome> {
        await FlotsamSignpost.measure("retention.sweep") { () async -> FlotsamResult<SweepOutcome> in
            var deleted = 0
            if let period = preset.periodMillis {
                switch await sweepOldItems(period: period) {
                case .success(let count): deleted = count
                case .failure(let error): return .failure(error)
                }
            }
            if deleted > 0 {
                FlotsamLog.log(
                    FlotsamError(.stoPol001, "Retention sweep", context: [.count: .int(deleted)]), category: .storage)
            }
            switch await enforceImageBudget(budget) {
            case .failure(let error): return .failure(error)
            case .success(let outcome):
                await stampLastSweep()
                return .success(SweepOutcome(retentionDeleted: deleted, budget: outcome))
            }
        }
    }

    private func sweepOldItems(period: Int64) async -> FlotsamResult<Int> {
        var total = 0
        while true {
            let arguments = eligibleArguments(period) + [Self.sweepBatchSize]
            let ids: [UUID]
            do {
                ids = try await pool.read { db in
                    try String.fetchAll(
                        db,
                        sql: "SELECT id FROM item WHERE \(Self.eligibleSQL()) ORDER BY lastCopiedAt ASC, id ASC LIMIT ?",
                        arguments: arguments
                    ).compactMap(UUID.init(uuidString:))
                }
            } catch {
                return .failure(Self.readFailure(error))
            }
            guard !ids.isEmpty else { return .success(total) }
            FlotsamSignpost.event("retention.sweep.batch")
            switch await delete(ids: ids) {
            case .failure(let error): return .failure(error)
            case .success(let removed):
                total += removed.count
                // Nothing removed means the rows vanished under us; looping again would only re-read them.
                if removed.isEmpty { return .success(total) }
            }
        }
    }

    /// `retention.lastSweepAt` is diagnostic only (About, logs); a failed stamp must not fail a sweep that worked.
    private func stampLastSweep() async {
        let now = clock.now().epochMillis
        try? await pool.write { db in try MetaStore.setInt64(db, MetaKey.retentionLastSweepAt, now) }
    }
}
