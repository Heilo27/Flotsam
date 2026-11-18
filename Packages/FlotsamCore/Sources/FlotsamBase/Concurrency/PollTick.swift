import Foundation

/// The one recurring wake-up source of the app (truth S5, ADR-0004), and the single owner of its cadence. The timer
/// owner (capture's poll timer) calls `fire()` once per timer firing and schedules that timer at `cadence`; slower
/// periodic work (the tap watchdog, the screenshot folder re-resolve) registers here with `every` instead of owning
/// a timer.
///
/// Time is counted in base ticks of `interval` (0.5 s). While the pasteboard poll needs the 0.5 s tick (the default,
/// `setFastTickNeeded(true)`) every firing is one base tick. While it does not (capture Paused, FR-001-19), the
/// cadence is the coarsest one every registered period divides (the greatest common divisor of their ticks: 5 s with
/// the watchdog, 30 s with only the re-resolve) and each firing advances that many base ticks, so registered work
/// still runs on every multiple of its period. When the cadence changes, work due before the first firing at the
/// new cadence runs at once, so no period is ever stretched by a change.
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
        /// Base ticks elapsed.
        var count = 0
        var nextId = 0
        var entries: [Int: Entry] = [:]
        var fastNeeded = true
        var observer: (@Sendable () -> Void)?

        /// Base ticks per timer firing, or nil when nothing needs a firing.
        var step: Int? {
            if fastNeeded { return 1 }
            if entries.isEmpty { return nil }
            return entries.values.reduce(0) { Self.gcd($0, $1.ticks) }
        }

        /// The work whose period boundary lies in `(from, to]`, finest period first so the poll's own cadence goes ahead
        /// of slower jobs, then in registration order.
        func due(from: Int, to: Int, excluding skipped: Int? = nil) -> [@Sendable () -> Void] {
            entries
                .filter { $0.key != skipped && to / $0.value.ticks > from / $0.value.ticks }
                .sorted { ($0.value.ticks, $0.key) < ($1.value.ticks, $1.key) }
                .map(\.value.work)
        }

        private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    }

    private let state = LockedValue(State())

    public init() {}

    /// Seconds between timer firings now, or nil when nothing needs one (capture Paused and no work registered).
    public var cadence: TimeInterval? {
        state.withLock { $0.step }.map { Double($0) * Self.interval }
    }

    /// Whether the pasteboard poll needs the 0.5 s tick. True by default; capture sets it false while Paused
    /// (FR-001-19) and true again on resume. Changing it changes `cadence`.
    public func setFastTickNeeded(_ needed: Bool) {
        change { $0.fastNeeded = needed }
    }

    /// Registers the one observer told whenever `cadence` changes, so the timer owner can reschedule. Called on
    /// whichever thread made the change; read `cadence` in it rather than trusting the order of calls.
    public func observeCadence(_ observer: @escaping @Sendable () -> Void) {
        state.withLock { $0.observer = observer }
    }

    /// Runs `work` on every `seconds / interval`-th tick (rounded to a whole tick, at least one). Returns the cancel
    /// closure; call it when the work no longer applies.
    public func every(_ seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let ticks = max(1, Int((seconds / Self.interval).rounded()))
        let id = state.withLock { state -> Int in
            state.nextId += 1
            return state.nextId
        }
        change(excluding: id) { $0.entries[id] = Entry(ticks: ticks, work: work) }
        return { [weak self] in self?.change { $0.entries[id] = nil } }
    }

    /// One firing of the poll timer: runs the work whose period has elapsed.
    public func fire() {
        let due = state.withLock { state -> [@Sendable () -> Void] in
            let before = state.count
            state.count += state.step ?? 1
            return state.due(from: before, to: state.count)
        }
        for work in due { work() }
    }

    /// How many pieces of work are registered; zero means nothing but the poll itself is scheduled.
    public var registrationCount: Int { state.withLock { $0.entries.count } }

    /// Applies `mutation`; when it changes the cadence, aligns the count to the new cadence (running the work that
    /// falls due in the gap, except the entry being registered) and tells the observer.
    private func change(excluding skipped: Int? = nil, _ mutation: @escaping @Sendable (inout State) -> Void) {
        let (due, observer) = state.withLock { state -> ([@Sendable () -> Void], (@Sendable () -> Void)?) in
            let before = state.step
            mutation(&state)
            let after = state.step
            guard after != before else { return ([], nil) }
            var due: [@Sendable () -> Void] = []
            if let after, after > 1, state.count % after != 0 {
                let aligned = (state.count / after + 1) * after
                due = state.due(from: state.count, to: aligned, excluding: skipped)
                state.count = aligned
            }
            return (due, state.observer)
        }
        for work in due { work() }
        observer?()
    }
}
