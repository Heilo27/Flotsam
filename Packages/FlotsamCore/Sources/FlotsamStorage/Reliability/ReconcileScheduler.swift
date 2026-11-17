import FlotsamBase
import Foundation

/// Runs reconcile shortly after launch and then weekly (FR-007-13).
///
/// The launch pass waits a short while so it never competes with the first window and the first sweep for the one
/// writer. Reconcile is a repair pass, not a hot path: if it fails it logs and tries again next week.
public actor ReconcileScheduler {
    private static let launchDelay: Duration = .seconds(15)
    private static let interval: Duration = .seconds(7 * 24 * 60 * 60)

    private let database: FlotsamDatabase
    private var loop: Task<Void, Never>?
    private var running = false

    public init(database: FlotsamDatabase) { self.database = database }

    /// Idempotent: a second call while running does nothing.
    public func start() {
        guard loop == nil else { return }
        let clock = database.clock
        loop = Task { [weak self] in
            // The clock port's sleep never throws: on cancellation it returns early, so stop() is observed here.
            await clock.sleep(for: Self.launchDelay)
            while !Task.isCancelled {
                await self?.reconcileNow()
                await clock.sleep(for: Self.interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One pass now; a pass already in progress is not doubled up.
    @discardableResult
    public func reconcileNow() async -> ReconcileOutcome? {
        guard !running else { return nil }
        running = true
        defer { running = false }
        switch await database.reconcile() {
        case .success(let outcome): return outcome
        case .failure(let error):
            database.report(error)
            return nil
        }
    }
}
