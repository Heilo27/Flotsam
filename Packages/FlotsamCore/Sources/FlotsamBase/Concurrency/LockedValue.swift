import Foundation
import os

/// A value guarded by an unfair lock, for state shared between the tap thread and everything else (ADR-0007).
///
/// Lives in Base because feature targets may not import `os` (ADR-0001) and `Synchronization.Mutex` needs macOS 15.
/// `OSAllocatedUnfairLock` owns the state it guards, so the compiler checks Sendability and no `@unchecked` is needed.
/// Hold the lock for a few instructions only: never call out, log or allocate inside `body` (FR-005-21).
public final class LockedValue<State: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<State>

    public init(_ initial: State) { lock = OSAllocatedUnfairLock(initialState: initial) }

    public func withLock<R: Sendable>(_ body: @Sendable (inout State) -> R) -> R { lock.withLock(body) }

    public var value: State { lock.withLock { $0 } }
}
