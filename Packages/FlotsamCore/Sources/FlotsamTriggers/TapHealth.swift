import FlotsamBase
import Foundation

/// What to do about a tap macOS has just disabled (FR-005-19).
public enum DisableVerdict: Sendable, Equatable {
    /// Under the limit: turn the tap back on.
    case reenable
    /// The limit was reached inside the window: leave it off until the user toggles triggers off and on, or relaunches.
    case latch
}

/// Counts how often the tap was disabled and decides when to stop re-enabling it (FR-005-19: three times within 60 s).
///
/// `Sendable` and lock-based because the tap thread records a disablement (`onDisabled`) while the main actor reads
/// `isLatched` and resets it. The latch is memory only, so a relaunch clears it as the FRD requires.
public final class TapHealth: Sendable {
    private struct State: Sendable {
        var disabledAt: [Date] = []
        var isLatched = false
    }

    private let state = LockedValue(State())
    private let clock: any WallClock
    private let limit: Int
    private let window: TimeInterval

    public init(
        clock: any WallClock, limit: Int = TriggerKeys.disableLimit, window: Duration = TriggerKeys.disableWindow
    ) {
        self.clock = clock
        self.limit = limit
        self.window = window.seconds
    }

    public var isLatched: Bool { state.value.isLatched }

    /// Records one disablement and says what to do. Once latched, every later call also says `.latch`.
    @discardableResult
    public func recordDisable() -> DisableVerdict {
        let now = clock.now()
        let cutoff = now.addingTimeInterval(-window)
        let limit = limit
        return state.withLock { state in
            state.disabledAt.removeAll { $0 < cutoff }
            state.disabledAt.append(now)
            if state.disabledAt.count >= limit { state.isLatched = true }
            return state.isLatched ? .latch : .reenable
        }
    }

    /// The user toggled triggers off: forget the history and lift the latch (FR-005-19).
    public func reset() { state.withLock { $0 = State() } }
}
