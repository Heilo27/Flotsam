import FlotsamBase
import Foundation

/// How an item is read aloud and aged in words. One home (FR-003-21, FR-006-19): the Library's rows and the Shelf's cards
/// both build their VoiceOver label here, so "the Library's form" cannot drift between the two surfaces.
public enum ItemSpeech {
    /// VoiceOver reads at most this many characters of the primary line (FR-003-21).
    public static let primaryLimit = 100

    /// "Text, hello, from Notes, 2 min ago, pinned": kind, primary line, source app (when known), age, pin state.
    public static func label(for row: ItemRow, now: Date) -> String {
        // A secure item is never read aloud as its mask (eight "bullet"s): it is "Secure item", plus "Unavailable" when
        // its key is gone.
        var spoken: [String]
        if row.isSecure {
            spoken = [template("ui.library.spokenSecure")]
            if row.isUnavailable { spoken.append(row.primaryLine) }
        } else {
            spoken = [KindLabel.text(for: row.kind), String(row.primaryLine.prefix(primaryLimit))]
        }
        if let source = row.sourceName, !source.isEmpty {
            spoken.append(String(format: template("ui.library.fromApp"), source))
        }
        spoken.append(relativeTime(row.lastCopiedAt, now: now))
        if row.isPinned { spoken.append(template("ui.library.spokenPinned")) }
        return spoken.joined(separator: ", ")
    }

    /// Items older than this read as a date, not a relative phrase (FR-003-07).
    public static let relativeWindow: TimeInterval = 7 * 86_400

    /// "2 min ago", "Yesterday", then a date once the copy is more than 7 days old (FR-003-07). A copy time slightly in
    /// the future (clock skew) reads as now, never as "in 1 min". Days are counted on `calendar`.
    public static func relativeTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let copied = min(date, now)
        if now.timeIntervalSince(copied) > relativeWindow {
            return copied.formatted(date: .abbreviated, time: .omitted)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        formatter.calendar = calendar
        let phrase = formatter.localizedString(for: copied, relativeTo: now)
        // The formatter's own word for one day back stands alone as a label, so it opens with a capital.
        let yesterday = formatter.localizedString(from: DateComponents(day: -1))
        return phrase == yesterday ? phrase.localizedCapitalized : phrase
    }

    /// Seconds until `relativeTime(date, now:)` next reads differently, or nil when it never will again (a dated copy, more
    /// than 7 days old). The label's finest step is the one the formatter shows for the copy's age: seconds under a
    /// minute ("5s ago"), then minutes, then hours, each cut off (never rounded) at its step. From the first calendar day
    /// on, the formatter counts days on `calendar`, not 86,400 s units, so the next change is the next calendar day after
    /// the copy's time of day, which is 23 or 25 hours away across a daylight-saving change, but never later than the second
    /// the copy passes the 7-day cutoff (the last day label turns into a date on time, FR-003-24). A copy dated ahead of `now`
    /// reads "now" until a second after its date. This is the one rule for how often a visible label needs a fresh `now`
    /// (FR-003-24).
    public static func secondsUntilRelativeTimeChanges(
        _ date: Date, now: Date, calendar: Calendar = .current
    ) -> TimeInterval? {
        if date > now { return date.timeIntervalSince(now) + 1 }
        let age = now.timeIntervalSince(date)
        if age > relativeWindow { return nil }
        let firstDay = calendar.date(byAdding: .day, value: 1, to: date)
        if let firstDay, now >= firstDay {
            // The cutoff is an absolute 604,800 s, not calendar days, so a day step that would land past it (a
            // daylight-saving week is 23 h short or 25 h long) is cut back to the second the copy turns a date.
            let untilCutoff = date.addingTimeInterval(relativeWindow + 1).timeIntervalSince(now)
            let days = max(calendar.dateComponents([.day], from: date, to: now).day ?? 1, 1)
            if let next = calendar.date(byAdding: .day, value: days + 1, to: date), next > now {
                return min(next.timeIntervalSince(now), untilCutoff)
            }
            return min(3_600, untilCutoff)  // the calendar could not name the next day: poll hourly rather than guess
        }
        let step: TimeInterval = age < 60 ? 1 : age < 3_600 ? 60 : 3_600
        let untilStep = step - age.truncatingRemainder(dividingBy: step)
        // A day boundary that falls before the next whole step (a daylight-saving day is 23 or 25 hours long) wins.
        return firstDay.map { min(untilStep, $0.timeIntervalSince(now)) } ?? untilStep
    }

    private static func template(_ key: String) -> String { FlotsamStrings.text(forKey: key) ?? "" }
}
