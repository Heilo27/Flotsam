import Foundation

/// The "still working" spinner of the Library and the Shelf (FR-003-50, FR-006-32): it turns on only once a load or
/// search has run for `delay`, so a load that finishes sooner never flashes one.
///
/// The delay is one one-shot task, armed when the first load of a busy period begins and cancelled when the period
/// ends. Nothing repeats, and nothing is armed while the panel is idle (truth S5, ADR-0004). A load that replaces
/// another one inside the same busy period (a keystroke while typing) neither restarts the delay nor hides a spinner
/// that is already showing, so continuous typing on a slow read still reaches the spinner.
@MainActor
@Observable
public final class BusyIndicator {
    /// The one delay both panels use (FR-003-50, FR-006-32).
    public static let delay: Duration = .milliseconds(150)

    /// The spinner's caption: "Searching…" while a search is typed, else "Loading…". One home for both panels; the Shelf
    /// reuses the Library's catalogue keys, as it does for its other shared words.
    public static func label(isSearching: Bool) -> String {
        FlotsamStrings.text(forKey: isSearching ? "ui.library.searching" : "ui.library.loading") ?? ""
    }

    /// True once the busy period has outlasted `delay`; false from `end()` on.
    public private(set) var isVisible = false

    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `sleep` is the owner's clock (`WallClock.sleep`, `ShelfClock.sleep`), so a test advances time by hand. It must
    /// return early on cancellation, as both clocks do.
    public init(sleep: @escaping @Sendable (Duration) async -> Void) {
        self.sleep = sleep
    }

    /// True while the delay timer is armed. False when idle and once the spinner is showing.
    public var isTimerArmed: Bool { task != nil }

    /// A load or search starts. Arms the delay unless a busy period is already running.
    public func begin() {
        guard task == nil, !isVisible else { return }
        let sleep = sleep
        task = Task { [weak self] in
            await sleep(Self.delay)
            guard !Task.isCancelled else { return }
            self?.delayElapsed()
        }
    }

    /// The load finished, failed, or was dropped (the panel hid): cancel the timer and hide the spinner.
    public func end() {
        task?.cancel()
        task = nil
        isVisible = false
    }

    private func delayElapsed() {
        task = nil
        isVisible = true
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for a clock that takes one (`ShelfClock`).
    public var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
