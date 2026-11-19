import FlotsamBase
import FlotsamStorage

/// The Storage calls the Settings window makes, as closures, so the window does not own or open the database and the
/// composition root decides which database it talks to (FRD-007). Every call is async and returns a `FlotsamResult`.
struct SettingsStorage: Sendable {
    var usage: @Sendable () async -> FlotsamResult<StorageUsage>
    var itemCounts: @Sendable () async -> FlotsamResult<[ItemKind: Int]>
    var retentionPreview: @Sendable (RetentionPreset) async -> FlotsamResult<DeletionPreview>
    var budgetPreview: @Sendable (ImageBudget) async -> FlotsamResult<DeletionPreview>
    var clearPreview: @Sendable (ClearRange, Bool) async -> FlotsamResult<DeletionPreview>
    var clear: @Sendable (ClearRange, Bool) async -> FlotsamResult<ClearOutcome>
    var sweep: @Sendable (RetentionPreset, ImageBudget) async -> FlotsamResult<SweepOutcome>

    /// `database` is asked on every call, because the database opens after launch and may not be open yet when the
    /// window is built; while it is nil every call fails with `STO-DB-004`.
    init(database: @escaping @MainActor @Sendable () -> FlotsamDatabase?) {
        let missing = FlotsamError(.stoDb004, "Settings storage is not available")
        usage = { guard let db = await database() else { return .failure(missing) }; return await db.storageUsage() }
        itemCounts = { guard let db = await database() else { return .failure(missing) }; return await db.itemCountsByKind() }
        retentionPreview = { preset in
            guard let db = await database() else { return .failure(missing) }
            return await db.retentionPreview(preset)
        }
        budgetPreview = { budget in
            guard let db = await database() else { return .failure(missing) }
            return await db.imageBudgetEvictionPreview(budget)
        }
        clearPreview = { range, exempt in
            guard let db = await database() else { return .failure(missing) }
            return await db.clearHistoryPreview(range: range, includeExempt: exempt)
        }
        clear = { range, exempt in
            guard let db = await database() else { return .failure(missing) }
            return await db.clearHistory(range: range, includeExempt: exempt)
        }
        sweep = { preset, budget in
            guard let db = await database() else { return .failure(missing) }
            return await db.runRetentionSweep(preset: preset, budget: budget)
        }
    }
}
