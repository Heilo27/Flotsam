import Foundation

/// The one loop that keeps a panel's relative times and VoiceOver ages current while it is shown (FRD-003 FR-003-24,
/// FRD-006 FR-006-48). The Library's rows and the Shelf's cards each own what to watch (their dates, whether they are
/// shown, their clock, what to do on a wake); the step rule is `ItemSpeech.secondsUntilRelativeTimeChanges` and the
/// loop is here, so the two panels cannot drift apart. It is not a timer: it sleeps until the soonest visible label is
/// due and returns when nothing needs a wake.
public enum RelativeTimeWatch {
    /// Added to each sleep so the wake lands just after a label's boundary, never just before it.
    public static let slack: TimeInterval = 0.05

    /// Sleeps until the soonest label in `dates` is due to read differently, then calls `refresh`, and repeats. Returns
    /// when the caller's task is cancelled, `isShown` turns false, or no label can change again (all dated), so a
    /// hidden panel costs no wake-ups and a panel of old items sleeps. The caller restarts it when the dates change.
    /// Each pass reads `now` once.
    @MainActor
    public static func run(
        dates: () -> [Date], isShown: () -> Bool, now: () -> Date, sleep: (TimeInterval) async -> Void,
        refresh: () -> Void
    ) async {
        while !Task.isCancelled, isShown() {
            let reading = now()
            let due = dates().compactMap { ItemSpeech.secondsUntilRelativeTimeChanges($0, now: reading) }.min()
            guard let due else { return }
            await sleep(due + slack)
            guard !Task.isCancelled, isShown() else { return }
            refresh()
        }
    }
}
