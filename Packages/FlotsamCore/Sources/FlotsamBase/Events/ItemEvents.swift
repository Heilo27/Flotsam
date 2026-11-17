import Foundation

/// What happened to stored items. Published by Storage after the transaction commits (FR-007-05, FR-007-15).
public enum ItemEvent: Sendable, Equatable {
    /// Items were created, bumped or edited: Library, Shelf and counts refresh (FRD-004 FR-004-13).
    case itemsChanged
    /// Items were removed. Subscribers (hotkey registry, trigger snapshot) must drop them immediately.
    case itemsDeleted([UUID])
}

/// A synchronous fan-out of `ItemEvent`s.
///
/// Why synchronous and not an `AsyncStream`: FR-007-15 requires a deleted item's hotkey and trigger to stop working
/// "before the delete call returns". An async stream only schedules delivery; a handler called inline guarantees it.
/// Handlers therefore run on the publisher's executor and must be quick and non-blocking (copy a snapshot, hop to
/// another actor, or yield into their own `AsyncStream` via `stream()`).
/// Lives in Base so Shortcuts and Triggers can subscribe without importing Storage internals.
public final class ItemEventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (ItemEvent) -> Void] = [:]

    public init() {}

    /// Registers a handler; call the returned closure to unsubscribe.
    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (ItemEvent) -> Void) -> @Sendable () -> Void {
        let token = UUID()
        lock.withLock { handlers[token] = handler }
        return { [weak self] in self?.lock.withLock { self?.handlers[token] = nil } }
    }

    /// Delivers `event` to every current subscriber before returning.
    public func publish(_ event: ItemEvent) {
        // Snapshot under the lock, call outside it: a handler may subscribe or unsubscribe without deadlocking.
        let snapshot = lock.withLock { Array(handlers.values) }
        for handler in snapshot { handler(event) }
    }

    /// An `AsyncStream` view for subscribers that do not need synchronous delivery (Library refresh).
    public func stream() -> AsyncStream<ItemEvent> {
        AsyncStream { continuation in
            let unsubscribe = subscribe { continuation.yield($0) }
            continuation.onTermination = { _ in unsubscribe() }
        }
    }
}
