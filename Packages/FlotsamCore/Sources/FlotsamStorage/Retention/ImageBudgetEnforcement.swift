import FlotsamBase
import Foundation
import GRDB

extension ImageBudget {
    /// Nil for Unlimited. The byte values live here, in Storage, because enforcement is the only thing that needs them.
    var limitBytes: Int64? {
        switch self {
        case .mib500: 500 * 1024 * 1024
        case .gib2: 2 * 1024 * 1024 * 1024
        case .gib10: 10 * 1024 * 1024 * 1024
        case .unlimited: nil
        }
    }
}

/// What one budget pass did (FR-007-08).
public struct BudgetOutcome: Sendable, Equatable {
    public let evictedCount: Int
    /// `STO-LIM-001` when exempt (and just-ingested) images alone are over budget and the 24 h throttle allows
    /// another Notice. Storage cannot show a Notice itself; the caller puts this in front of the user.
    public let notice: FlotsamError?
}

extension FlotsamDatabase {
    /// Evicted items are taken down to this share of the budget, not to the budget itself, so one eviction buys
    /// headroom for several more images instead of re-running on every ingest (FR-007-08).
    private static let evictionTargetPercent: Int64 = 90
    /// At most one `STO-LIM-001` Notice per this window (FR-007-08, `budget.lastNoticeAt`).
    private static let noticeThrottleMillis: Int64 = 24 * 60 * 60 * 1000
    private static let evictionBatchSize = 500

    /// Keeps stored image bytes within `budget` (FR-007-08). Called after each image ingest and by every retention sweep.
    ///
    /// The total counts `representation.byteSize` of image and screenshot items only: thumbnails, text and files held
    /// by reference are not Flotsam's image storage. When over budget, non-exempt image items go oldest
    /// `lastCopiedAt` first until the total is at most 90 % of the budget. `protecting` is the item that was just
    /// ingested: evicting the thing the user just copied would make the copy appear to vanish.
    ///
    /// Exempt items (FR-007-10) are never candidates. If they and `protecting` alone still exceed the budget, that
    /// is surfaced as `STO-LIM-001` rather than solved by deleting what the user pinned.
    ///
    /// Deletion goes through `delete(ids:)` in batches, so each transaction holds the writer briefly and blobs,
    /// thumbnails and `itemsDeleted` are handled in one place.
    public func enforceImageBudget(_ budget: ImageBudget, protecting: UUID? = nil) async -> FlotsamResult<BudgetOutcome> {
        guard let limit = budget.limitBytes else { return .success(BudgetOutcome(evictedCount: 0, notice: nil)) }

        let plan: [ImageCandidate]
        let total: Int64
        do {
            (total, plan) = try await pool.read { db in
                let total = try Self.imageBytes(db)
                guard total > limit else { return (total, []) }
                return (total, try Self.evictionCandidates(db, protecting: protecting))
            }
        } catch {
            return .failure(Self.readFailure(error))
        }
        guard total > limit else { return .success(BudgetOutcome(evictedCount: 0, notice: nil)) }

        let target = limit * Self.evictionTargetPercent / 100
        var remaining = total
        var chosen: [UUID] = []
        for candidate in plan where remaining > target {
            chosen.append(candidate.id)
            remaining -= candidate.bytes
        }

        var evicted = 0
        for batch in chosen.chunked(into: Self.evictionBatchSize) {
            switch await delete(ids: batch) {
            case .success(let removed): evicted += removed.count
            case .failure(let error): return .failure(error)
            }
        }
        if evicted > 0 {
            FlotsamLog.log(
                FlotsamError(.stoPol001, "Image budget eviction", context: [.count: .int(evicted)]), category: .storage)
        }

        // Still over after every candidate went: what is left is exempt or protected.
        let notice = remaining > limit ? await budgetNoticeIfDue() : nil
        return .success(BudgetOutcome(evictedCount: evicted, notice: notice))
    }

    /// How many bytes of images are stored, for the retention confirmation as well as enforcement.
    static func imageBytes(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT COALESCE(SUM(representation.byteSize), 0)
                FROM representation JOIN item ON item.id = representation.itemId
                WHERE item.kind IN ('image', 'screenshot')
                """) ?? 0
    }

    private struct ImageCandidate: Sendable {
        let id: UUID
        let bytes: Int64
    }

    /// Non-exempt image items, oldest first, each with its own stored bytes: one query, no per-item look-ups.
    private static func evictionCandidates(_ db: Database, protecting: UUID?) throws -> [ImageCandidate] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT item.id AS id, SUM(representation.byteSize) AS bytes
                FROM item JOIN representation ON representation.itemId = item.id
                WHERE item.kind IN ('image', 'screenshot') AND \(Exemption.notExemptSQL) AND item.id != ?
                GROUP BY item.id
                ORDER BY item.lastCopiedAt ASC, item.id ASC
                """,
            arguments: [protecting?.uuidString ?? ""]
        ).compactMap { row in
            (UUID(uuidString: row["id"])).map { ImageCandidate(id: $0, bytes: row["bytes"]) }
        }
    }

    /// Returns `STO-LIM-001` and stamps `budget.lastNoticeAt` when none was raised in the last 24 h. Read and stamp
    /// share one transaction so two racing passes cannot both raise it. A failed stamp means no Notice: showing one
    /// that cannot be throttled would repeat it.
    private func budgetNoticeIfDue() async -> FlotsamError? {
        let now = clock.now().epochMillis
        let due = try? await pool.write { db -> Bool in
            if let last = try MetaStore.int64(db, MetaKey.budgetLastNoticeAt), now - last < Self.noticeThrottleMillis {
                return false
            }
            try MetaStore.setInt64(db, MetaKey.budgetLastNoticeAt, now)
            return true
        }
        return due == true ? FlotsamError(.stoLim001, "Exempt images alone exceed the image budget") : nil
    }
}
