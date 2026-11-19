import Foundation

/// The lengths the menu-bar "Pause For" submenu offers (FR-007-12, FR-008-16). The one home of what each choice means
/// and of its catalogue key.
public enum PauseDuration: CaseIterable, Sendable, Equatable {
    case fifteenMinutes, oneHour, untilTomorrow

    public var titleKey: String {
        switch self {
        case .fifteenMinutes: "ui.menu.pause15Minutes"
        case .oneHour: "ui.menu.pause1Hour"
        case .untilTomorrow: "ui.menu.pauseUntilTomorrow"
        }
    }

    /// When the pause ends, as UTC milliseconds since epoch. "Until Tomorrow" ends at the next local midnight, so it
    /// covers the rest of today whatever time it is chosen at. If the calendar cannot name that midnight the pause
    /// falls back to 24 hours rather than failing.
    public func deadlineMillis(from now: Date, calendar: Calendar = .current) -> Int64 {
        let end: Date
        switch self {
        case .fifteenMinutes: end = now.addingTimeInterval(15 * 60)
        case .oneHour: end = now.addingTimeInterval(60 * 60)
        case .untilTomorrow:
            end = calendar.nextDate(
                after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(24 * 60 * 60)
        }
        return TimedPause.millis(end)
    }
}

/// A timed pause (FR-007-12): Paused capture mode plus the moment it ends. The deadline is state, not a preference, so
/// it is not a registry row (like the onboarding resume step, FR-008-01); it is stored beside the settings and is
/// meaningful only while `capture.mode` is Paused.
///
/// Exactly one timer exists, and only while a deadline is pending: a single sleep until the deadline (ADR-0004), never
/// a poll. Everything funnels through `reconcile()`, which reads the stored deadline and the mode and does the one
/// thing that is right: resume when the deadline has passed, re-arm when it has not, drop the deadline when the user
/// left Paused by hand (Resume Capture, or Curated in Settings). Launch and wake call it too, because a sleep that
/// spans the Mac sleeping is not guaranteed to count that time, and because a quit mid-pause must not turn a timed
/// pause into an indefinite one.
@MainActor
public final class TimedPause {
    static let keyName = "capture.pauseUntil"

    private let settings: SettingsStore
    private let store: any KeyValueStore
    private let clock: any WallClock
    private var timer: Task<Void, Never>?
    private var unsubscribe: (@Sendable () -> Void)?

    public init(settings: SettingsStore, store: any KeyValueStore, clock: any WallClock = SystemClock()) {
        self.settings = settings
        self.store = store
        self.clock = clock
        unsubscribe = settings.subscribe { [weak self] change in
            guard change.name == SettingKeys.captureMode.name else { return }
            Task { @MainActor in self?.reconcile() }
        }
    }

    deinit {
        unsubscribe?()
        timer?.cancel()
    }

    nonisolated static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// The pending deadline in UTC milliseconds, or nil when none is stored or the stored text is not a number.
    public var deadlineMillis: Int64? {
        guard let raw = store.string(forKey: Self.keyName), let value = Int64(raw), value > 0 else { return nil }
        return value
    }

    /// Pauses capture for `duration` from now. The deadline is written before the mode so that the mode change this
    /// makes is never read as the user leaving Paused.
    public func pause(for duration: PauseDuration, calendar: Calendar = .current) {
        let deadline = duration.deadlineMillis(from: clock.now(), calendar: calendar)
        store.setString(String(deadline), forKey: Self.keyName)
        settings.set(.paused, for: SettingKeys.captureMode)
        reconcile()
    }

    /// Brings the timer and the stored deadline in line with the capture mode and the clock. Safe to call at any time.
    public func reconcile() {
        guard let deadline = deadlineMillis else {
            cancelTimer()
            return
        }
        guard settings.value(SettingKeys.captureMode) == .paused else {
            clearDeadline()
            return
        }
        let remaining = deadline - Self.millis(clock.now())
        guard remaining > 0 else {
            clearDeadline()
            settings.set(.active, for: SettingKeys.captureMode)
            return
        }
        arm(remainingMillis: remaining)
    }

    private func arm(remainingMillis: Int64) {
        // Always replaces the sleep: after a wake `reconcile` is called precisely so a sleep that did not count the Mac's
        // own sleep is swapped for one that measures what is really left.
        timer?.cancel()
        let clock = clock
        timer = Task { [weak self] in
            await clock.sleep(for: .milliseconds(remainingMillis))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    private func clearDeadline() {
        store.removeValue(forKey: Self.keyName)
        cancelTimer()
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
