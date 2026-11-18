import FlotsamBase
import Foundation

/// How an item is read aloud and aged in words. One home (FR-003-21, FR-006-19): the Library's rows and the Shelf's cards
/// both build their VoiceOver label here, so "the Library's form" cannot drift between the two surfaces.
public enum ItemSpeech {
    /// VoiceOver reads at most this many characters of the primary line (FR-003-21).
    public static let primaryLimit = 100

    /// "Text, hello, from Notes, 2 min ago, Pinned": kind, primary line, source app (when known), age, pin state.
    public static func label(for row: ItemRow, now: Date) -> String {
        var spoken = [KindLabel.text(for: row.kind), String(row.primaryLine.prefix(primaryLimit))]
        if let source = row.sourceName, !source.isEmpty {
            spoken.append(String(format: template("ui.library.fromApp"), source))
        }
        spoken.append(relativeTime(row.lastCopiedAt, now: now))
        if row.isPinned { spoken.append(template("ui.library.pinned")) }
        return spoken.joined(separator: ", ")
    }

    /// "2 min ago", "yesterday". A copy time slightly in the future (clock skew) reads as now, never as "in 1 min".
    public static func relativeTime(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    private static func template(_ key: String) -> String { FlotsamStrings.text(forKey: key) ?? "" }
}
