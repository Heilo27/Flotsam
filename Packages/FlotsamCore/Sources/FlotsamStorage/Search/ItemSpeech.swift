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
    /// the future (clock skew) reads as now, never as "in 1 min".
    public static func relativeTime(_ date: Date, now: Date) -> String {
        let copied = min(date, now)
        if now.timeIntervalSince(copied) > relativeWindow {
            return copied.formatted(date: .abbreviated, time: .omitted)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        let phrase = formatter.localizedString(for: copied, relativeTo: now)
        // The formatter's own word for one day back stands alone as a label, so it opens with a capital.
        let yesterday = formatter.localizedString(from: DateComponents(day: -1))
        return phrase == yesterday ? phrase.localizedCapitalized : phrase
    }

    /// Seconds until `relativeTime(date, now:)` next reads differently, or nil when it never will again (a dated copy, more
    /// than 7 days old). The label's finest step is the one the formatter shows for the copy's age: seconds under a
    /// minute ("5s ago"), then minutes, hours and days, each cut off (never rounded) at its step. This is the one rule for
    /// how often a visible label needs a fresh `now` (FR-003-07).
    public static func secondsUntilRelativeTimeChanges(_ date: Date, now: Date) -> TimeInterval? {
        let age = now.timeIntervalSince(min(date, now))
        if age > relativeWindow { return nil }
        let step: TimeInterval = age < 60 ? 1 : age < 3_600 ? 60 : age < 86_400 ? 3_600 : 86_400
        return step - age.truncatingRemainder(dividingBy: step)
    }

    private static func template(_ key: String) -> String { FlotsamStrings.text(forKey: key) ?? "" }
}
