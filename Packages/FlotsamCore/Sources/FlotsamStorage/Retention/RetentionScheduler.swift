import FlotsamBase
import Foundation

/// Runs the retention sweep 30 s after launch, then hourly, and on demand for wake from sleep (FR-007-09).
///
/// Storage does not import AppKit, so the app layer observes the wake notification and calls `sweepNow()`. The
/// settings are read at each run, so a changed preset takes effect on the next sweep without restarting anything.
public actor RetentionScheduler {
    private static let launchDelay: Duration = .seconds(30)
    private static let interval: Duration = .seconds(60 * 60)

    private let database: FlotsamDatabase
    private let settings: SettingsStore
    private let onNotice: @Sendable (FlotsamError) -> Void
    private var loop: Task<Void, Never>?
    private var sweeping = false

    /// `onNotice` receives the budget's `STO-LIM-001` (already throttled to once per 24 h); the sweep itself never
    /// raises a Notice.
    public init(database: FlotsamDatabase, settings: SettingsStore, onNotice: @escaping @Sendable (FlotsamError) -> Void) {
        self.database = database
        self.settings = settings
        self.onNotice = onNotice
    }

    /// Idempotent: a second call while running does nothing.
    public func start() {
        guard loop == nil else { return }
        let clock = database.clock
        loop = Task { [weak self] in
            // The clock port's sleep never throws: on cancellation it returns early, so stop() is observed here.
            await clock.sleep(for: Self.launchDelay)
            while !Task.isCancelled {
                await self?.sweepNow()
                await clock.sleep(for: Self.interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One sweep now. A sweep already in progress is not doubled up: two overlapping sweeps would only contend
    /// for the one writer.
    public func sweepNow() async {
        guard !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        let preset = settings.value(SettingKeys.storageRetention)
        let budget = settings.value(SettingKeys.storageImageBudget)
        switch await database.runRetentionSweep(preset: preset, budget: budget) {
        case .success(let outcome):
            if let notice = outcome.budget.notice { onNotice(notice) }
        case .failure(let error):
            database.report(error)
        }
    }
}
