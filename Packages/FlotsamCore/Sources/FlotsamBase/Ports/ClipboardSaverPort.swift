import Foundation

/// What Save Clipboard did with the pasteboard right now (FR-005-06).
public enum SaveClipboardOutcome: Sendable, Equatable {
    /// A new item was stored, or the clip was already stored and its copy count bumped (FR-001-15).
    case saved
    /// Nothing was stored: a capture gate rejected it (`CAP-POL-001`, `CAP-POL-002`, `CAP-VAL-001`) or ingest failed
    /// (`CAP-LIM-001`, `CAP-IO-001`, `CAP-OS-001`). The caller shows it; Capture does not also raise a Notice for it.
    case rejected(FlotsamError)
}

/// Runs the capture pipeline on the current pasteboard on demand, regardless of capture mode (FR-005-06). Capture
/// implements it; Shortcuts depends only on this port, so it never imports Capture (ADR-0001).
@MainActor
public protocol ClipboardSaver {
    func saveClipboardNow() async -> SaveClipboardOutcome
}
