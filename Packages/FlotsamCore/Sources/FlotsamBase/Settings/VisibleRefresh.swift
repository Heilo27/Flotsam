import Foundation

/// The re-read of a permission status while the view showing it is visible (FR-008-13 rule b). It runs only between
/// `setVisible(true)` and `setVisible(false)`: nothing is scheduled while the Settings window is closed, minimised,
/// covered, or showing another pane, so the idle budget (truth S5, FR-001-20) is untouched. Reading a status never
/// triggers a prompt (rule a). The cadence lives here and nowhere else (Rule 9); the delay is the injected clock's
/// (ADR-0011), so tests step it by hand.
@MainActor
public final class VisibleRefresh {
    /// FR-008-13 rule (b): the status is re-read this often while visible.
    public static let interval: Duration = .seconds(2)

    private let clock: any WallClock
    private let refresh: @MainActor () -> Void
    private var task: Task<Void, Never>?

    /// `refresh` re-reads the status; it runs at once on becoming visible, then every `interval` until hidden.
    public init(clock: any WallClock = SystemClock(), refresh: @escaping @MainActor () -> Void) {
        self.clock = clock
        self.refresh = refresh
    }

    /// The window-event rule (FR-008-13 b): the view's status is read only while it is on screen (`onScreen`: appeared
    /// and not disappeared, i.e. its pane is selected) AND its host window is visible (`windowIsVisible`: the window's
    /// occlusion state includes visible; nil when the view has no window). A closed, minimised or covered window is not
    /// visible, so none of them runs the loop. The App's window observer calls this on every event and feeds the result
    /// to `setVisible`.
    public nonisolated static func isVisible(onScreen: Bool, windowIsVisible: Bool?) -> Bool {
        onScreen && windowIsVisible == true
    }

    /// Whether a refresh loop is currently scheduled.
    public var isRefreshing: Bool { task != nil }

    /// An owner that is dropped while visible stops the loop at once (the loop holds the owner weakly too, so a read
    /// can never outlive it).
    deinit { task?.cancel() }

    /// Starts the loop on becoming visible (a no-op when already visible) and cancels it on becoming hidden.
    public func setVisible(_ visible: Bool) {
        guard visible else {
            task?.cancel()
            task = nil
            return
        }
        guard task == nil else { return }
        let clock = clock
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                // Hold the owner only for the read, never across the sleep.
                await clock.sleep(for: Self.interval)
            }
        }
    }
}
