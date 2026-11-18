import Foundation

/// The one recurring wake-up source of the app (truth S5, ADR-0004): the pasteboard poll's timer calls `fire()` once
/// per tick, and slower periodic work (the tap watchdog, the screenshot folder re-resolve) registers here with
/// `every` instead of owning a timer. A period is a whole number of ticks, so the work runs on the poll's tick and
/// adds no wake-up of its own.
///
/// `fire()` runs the due work synchronously on the caller (the main actor, from the poll timer), so registered work
/// must return at once: start a `Task` for anything that suspends.
public final class PollTick: Sendable {
    /// FR-001-01: the poll period, which is the tick every other period is a multiple of.
    public static let interval: TimeInterval = 0.5
    /// FR-001-01.
    public static let tolerance: TimeInterval = 0.1

    private struct Entry {
        let ticks: Int
        let work: @Sendable () -> Void
    }

    private struct State {
        var count = 0
        var nextId = 0
        var entries: [Int: Entry] = [:]
    }

    private let state = LockedValue(State())

    public init() {}

    /// Runs `work` on every `seconds / interval`-th tick (rounded to a whole tick, at least one). Returns the cancel
    /// closure; call it when the work no longer applies.
    public func every(_ seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let ticks = max(1, Int((seconds / Self.interval).rounded()))
        let id = state.withLock { state -> Int in
            state.nextId += 1
            state.entries[state.nextId] = Entry(ticks: ticks, work: work)
            return state.nextId
        }
        return { [state] in state.withLock { $0.entries[id] = nil } }
    }

    /// One tick of the poll timer: runs the work whose period has elapsed.
    public func fire() {
        let due = state.withLock { state -> [@Sendable () -> Void] in
            state.count += 1
            let count = state.count
            return state.entries.values.filter { count % $0.ticks == 0 }.map(\.work)
        }
        for work in due { work() }
    }

    /// How many pieces of work are registered; zero means nothing but the poll itself is scheduled.
    public var registrationCount: Int { state.withLock { $0.entries.count } }
}
