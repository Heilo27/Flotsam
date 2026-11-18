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
    /// Stored bytes of the evicted items, for the sweep's `retention.swept` line (FR-000-11).
    public let evictedBytes: Int64
    /// `STO-LIM-001` when exempt (and just-ingested) images alone are over budget and the 24 h throttle allows
    /// another Notice. Storage cannot show a Notice itself; the caller puts this in front of the user.
    public let notice: FlotsamError?
}

extension FlotsamDatabase {
    /// Evicted items are taken down to this share of the budget, not to the budget itself, so one eviction buys
    /// headroom for several more images instead of re-running on every ingest (FR-007-08).
    private static let evictionTargetPercent: Int64 = 90
    /// At most one `STO-LIM-001` Notice per this window (FR-007-08, `budget.lastNoticeAt`).
    private static let noticeThrottleMillis: Int64 = TimeSpan.dayMillis
    private static let evictionBatchSize = 500

    /// Keeps stored image bytes within `budget` (FR-007-08). Called after each image ingest and by every retention sweep.
    ///
    /// The total counts `representation.byteSize` of image and screenshot items only: thumbnails, text and files held
    /// by reference are not Flotsam's image storage. When over budget, non-exempt image items go oldest
    /// `lastCopiedAt` first until the total is at most 90 % of the budget. `protecting` is the item that was just
    /// ingested: evicting the thing the user just copied would make the copy appear to vanish.
    ///
    /// Exempt items and items inside the 24 h release grace (FR-007-10) are never candidates, the same exemption the
    /// time sweep honours: an image un-pinned an hour ago must not be evicted just because the budget is full. If
    /// they and `protecting` alone still exceed the budget, that is surfaced as `STO-LIM-001` rather than solved by deleting what the user pinned.
    ///
    /// Deletion goes through `deleteWhileEligible(ids:guard:)` in batches, so each transaction holds the writer briefly and blobs,
    /// thumbnails and `itemsDeleted` are handled in one place.
    public func enforceImageBudget(_ budget: ImageBudget, protecting: UUID? = nil) async -> FlotsamResult<BudgetOutcome> {
        guard let limit = budget.limitBytes else { return .success(BudgetOutcome(evictedCount: 0, evictedBytes: 0, notice: nil)) }

        let now = clock.now().epochMillis
        let planned: BudgetPlan
        do {
            planned = try await pool.read { db in try Self.planBudgetEviction(db, limit: limit, protecting: protecting, now: now) }
        } catch {
            return .failure(Self.readFailure(error))
        }
        guard planned.total > limit else { return .success(BudgetOutcome(evictedCount: 0, evictedBytes: 0, notice: nil)) }
        let chosen = planned.evict
        let remaining = planned.remainingAfterEviction

        var evicted = 0
        var evictedBytes: Int64 = 0
        for batch in chosen.chunked(into: Self.evictionBatchSize) {
            // Re-checked at deletion: an image pinned or given a shortcut since the plan was made is kept.
            switch await deleteItemsWhileEligible(ids: batch, guard: Exemption.autoDeletableGuard(now: now)) {
            case .success(let removed):
                evicted += removed.count
                evictedBytes += removed.reduce(0) { $0 + $1.byteSize }
            case .failure(let error): return .failure(error)
            }
        }
        if evicted > 0 {
            report(FlotsamError(.stoPol001, "Image budget eviction", context: [.count: .int(evicted)]))
        }

        // Still over after every candidate went: what is left is exempt or protected.
        let notice = remaining > limit ? await budgetNoticeIfDue() : nil
        return .success(BudgetOutcome(evictedCount: evicted, evictedBytes: evictedBytes, notice: notice))
    }

    /// What a budget pass would delete, decided but not yet done.
    private struct BudgetPlan: Sendable {
        let total: Int64
        let evict: [UUID]
        let remainingAfterEviction: Int64
    }

    /// The one place the eviction choice is made, so the confirmation count and the real pass cannot disagree.
    private static func planBudgetEviction(_ db: Database, limit: Int64, protecting: UUID?, now: Int64) throws -> BudgetPlan {
        let total = try imageBytes(db)
        guard total > limit else { return BudgetPlan(total: total, evict: [], remainingAfterEviction: total) }
        let target = limit * evictionTargetPercent / 100
        var remaining = total
        var chosen: [UUID] = []
        for candidate in try evictionCandidates(db, protecting: protecting, now: now) where remaining > target {
            chosen.append(candidate.id)
            remaining -= candidate.bytes
        }
        return BudgetPlan(total: total, evict: chosen, remainingAfterEviction: remaining)
    }

    /// What `enforceImageBudget` would delete under `budget`, for the lower-budget confirmation (FR-007-09:
    /// "removes {count} older images ({size})"). Deletes nothing. It runs the same planner as enforcement, so the
    /// number the user confirms is the number removed. Count 0 means the caller applies the setting without asking.
    public func imageBudgetEvictionPreview(_ budget: ImageBudget) async -> FlotsamResult<DeletionPreview> {
        guard let limit = budget.limitBytes else { return .success(.none) }
        let now = clock.now().epochMillis
        do {
            return .success(try await pool.read { db in
                let plan = try Self.planBudgetEviction(db, limit: limit, protecting: nil, now: now)
                return DeletionPreview(count: plan.evict.count, bytes: plan.total - plan.remainingAfterEviction)
            })
        } catch {
            return .failure(Self.readFailure(error))
        }
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

    /// Evictable image items (not exempt, out of grace), oldest first, each with its own stored bytes: one query,
    /// no per-item look-ups.
    private static func evictionCandidates(_ db: Database, protecting: UUID?, now: Int64) throws -> [ImageCandidate] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT item.id AS id, SUM(representation.byteSize) AS bytes
                FROM item JOIN representation ON representation.itemId = item.id
                WHERE item.kind IN ('image', 'screenshot') AND \(Exemption.autoDeletableSQL) AND item.id != ?
                GROUP BY item.id
                ORDER BY item.lastCopiedAt ASC, item.id ASC
                """,
            arguments: [Exemption.graceCutoff(now: now), protecting?.uuidString ?? ""]
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
