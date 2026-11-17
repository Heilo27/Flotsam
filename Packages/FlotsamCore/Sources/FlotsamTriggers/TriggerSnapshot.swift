import FlotsamBase
import Foundation

/// Trigger text to item, as an immutable value (ADR-0007, FR-005-12). The tap reads it under a short lock and never
/// touches the database.
public struct TriggerSnapshot: Sendable, Equatable {
    private let itemsByKey: [String: UUID]

    public static let empty = TriggerSnapshot(itemsByKey: [:])

    private init(itemsByKey: [String: UUID]) { self.itemsByKey = itemsByKey }

    /// Builds from stored bindings. A trigger that fails the grammar is skipped, and so are all triggers that collide
    /// case-insensitively: the database's unique index should make that impossible, and a match must be exactly one
    /// item (FR-005-12), so an ambiguous word expands nothing rather than guessing.
    public init(bindings: ItemBindings) {
        var byKey: [String: UUID] = [:]
        var ambiguous: Set<String> = []
        for (id, trigger) in bindings.triggers {
            guard case .success = TriggerGrammar.validate(trigger) else { continue }
            let key = TriggerGrammar.canonicalKey(trigger)
            if byKey.updateValue(id, forKey: key) != nil { ambiguous.insert(key) }
        }
        for key in ambiguous { byKey[key] = nil }
        itemsByKey = byKey
    }

    public var isEmpty: Bool { itemsByKey.isEmpty }
    public var count: Int { itemsByKey.count }

    /// `key` must already be `TriggerGrammar.canonicalKey`.
    func itemId(forKey key: String) -> UUID? { itemsByKey[key] }

    func removing(_ ids: Set<UUID>) -> TriggerSnapshot {
        TriggerSnapshot(itemsByKey: itemsByKey.filter { !ids.contains($0.value) })
    }
}

/// What the tap callback reads at a match: the trigger snapshot and the excluded applications (FR-005-13 b).
public struct TriggerPolicy: Sendable, Equatable {
    public var triggers: TriggerSnapshot
    public var excludedApps: Set<String>

    public init(triggers: TriggerSnapshot = .empty, excludedApps: Set<String> = []) {
        self.triggers = triggers
        self.excludedApps = excludedApps
    }

    /// FR-005-13 b: the exclusion list plus Flotsam's own windows, which are always excluded and not editable. The
    /// matcher decides with it at the match and the expander decides again with it at step 2 (FR-005-14), so the two
    /// cannot disagree (Rule 9).
    public func excludes(bundleId: String, ownBundleId: String) -> Bool {
        bundleId == ownBundleId || excludedApps.contains(bundleId)
    }
}

/// The shared holder of `TriggerPolicy`. Writers (settings, item events) replace the value; the tap reads it.
///
/// FR-005-22: `remove(itemIds:)` is synchronous so a deleted item stops expanding before the delete returns. `replace`
/// is generation-guarded: a slow rebuild that started before a delete finished cannot bring the deleted trigger back.
public final class TriggerSnapshotStore: Sendable {
    private struct State: Sendable {
        var policy = TriggerPolicy()
        var generation = 0
    }

    private let state = LockedValue(State())

    public init() {}

    public var policy: TriggerPolicy { state.withLock { $0.policy } }

    /// Starts a rebuild: pair the returned token with the bindings read afterwards.
    public func beginRebuild() -> Int { state.withLock { $0.generation += 1; return $0.generation } }

    /// Installs `triggers` unless another change landed since `beginRebuild` returned `token`. True when installed.
    @discardableResult
    public func replace(_ triggers: TriggerSnapshot, token: Int) -> Bool {
        state.withLock {
            guard $0.generation == token else { return false }
            $0.policy.triggers = triggers
            return true
        }
    }

    public func remove(itemIds: [UUID]) {
        let ids = Set(itemIds)
        state.withLock {
            $0.generation += 1  // any rebuild already reading the database is now stale
            $0.policy.triggers = $0.policy.triggers.removing(ids)
        }
    }

    public func setExcludedApps(_ apps: Set<String>) { state.withLock { $0.policy.excludedApps = apps } }
}

/// A one-way request, from any thread, that the matcher clear its word at the next event (frontmost application
/// changed, wake from sleep, tap re-enabled; FR-005-11, FR-005-19).
public final class TriggerResetSignal: Sendable {
    private let pending = LockedValue(false)

    public init() {}

    public func request() { pending.withLock { $0 = true } }

    func consume() -> Bool { pending.withLock { let was = $0; $0 = false; return was } }
}
