import FlotsamBase
import Foundation

/// What text a user may type in to make or change a text item (FR-004-07, FR-004-19): at least one non-whitespace
/// character (`ORG-VAL-003`) and no more than the text ceiling (`ORG-LIM-003`). The one home of the rule, shared by
/// editing an item and by Add Clip, so the two cannot drift.
public enum TextEntryRules {
    /// Why `text` may not be stored, or nil when it may. `context` is added to the error (an item id, for an edit).
    public static func rejection(for text: String, context: [LogKey: LogSafeValue] = [:]) -> FlotsamError? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FlotsamError(.orgVal003, "Entered text has no visible character", context: context)
        }
        guard text.utf8.count <= IngestLimits.maxTextBytes else {
            return FlotsamError(
                .orgLim003, "Entered text is over the text ceiling",
                context: context.merging([.limitBytes: .bytes(IngestLimits.maxTextBytes)]) { _, new in new })
        }
        return nil
    }
}
