import AppKit
import FlotsamBase

/// The Fatal path (FR-000-04): a modal alert with the catalogue message, "Reveal Data Folder" and "Quit", then the
/// process ends. Only the two Fatal codes (STO-IO-002, STO-DB-003) reach here; `ErrorCode.severity` is the gate.
///
/// Why both buttons terminate: the app cannot run safely (no data folder, or a database it cannot open), so
/// dismissing the alert by any route leaves nothing useful to return to. Revealing the folder first lets the user
/// reach their untouched data or the damaged file before the process exits.
@MainActor
enum FatalAlert {
    /// Shows the alert and terminates after it is dismissed. Does nothing for a non-Fatal error, so a caller bug
    /// cannot take the app down for a Warning (AC-000-05: any other code leaves the process alive).
    static func present(for error: FlotsamError, dataFolder: URL) {
        guard error.severity == .fatal else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = FlotsamStrings.message(for: error)
        alert.addButton(withTitle: FlotsamStrings.text(forKey: "ui.fatal.revealDataFolder") ?? "")
        alert.addButton(withTitle: FlotsamStrings.text(forKey: "ui.fatal.quit") ?? "")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([nearestExistingFolder(from: dataFolder)])
        }
        NSApplication.shared.terminate(nil)
    }

    /// The folder itself if it exists, otherwise its closest existing ancestor.
    ///
    /// Why: STO-IO-002 means the data folder could not be created or opened, often because it does not exist.
    /// Finder does nothing when asked to select a missing path, so the one case the button is offered for would
    /// silently fail. Walking up reveals where the folder should be (normally Application Support) and, unlike
    /// creating it, leaves the disk exactly as the failure left it. Stops at the filesystem root, which exists.
    static func nearestExistingFolder(from folder: URL) -> URL {
        var candidate = folder
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return candidate
    }
}
