import Foundation

/// The HUD text for "Import recent screenshots" (FRD-002 FR-002-12): "Imported {n}". One home, so onboarding and
/// Settings, which share one import action, cannot word the result differently (FR-000-05).
public enum ScreenshotImportHUD {
    public static let key = "ui.hud.screenshotsImported"
    public static let importingKey = "ui.hud.screenshotsImporting"

    /// "Importing…", shown the moment the user presses the button: a backfill can take minutes (FR-002-12), and the
    /// result HUD only appears when it ends.
    public static var importingMessage: String { FlotsamStrings.text(forKey: importingKey) ?? importingKey }

    /// "Imported 3". A negative count reads as 0; a catalogue template whose placeholder is not one count is returned
    /// unfilled rather than handed to `String(format:)`.
    public static func message(count: Int) -> String {
        let template = FlotsamStrings.text(forKey: key) ?? key
        guard FlotsamStrings.placeholderKinds(in: template) == [.integer] else { return template }
        return String(format: template, max(0, count))
    }
}
