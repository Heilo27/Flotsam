import AppKit

/// Source app icons for the Shelf card header and the Library row lead, one lookup per app. The app may be gone from this Mac:
/// the Shelf then shows a generic app icon and the Library row its kind glyph. No disk access happens per frame, because the
/// answer (an icon or "no such app") is cached by bundle identifier.
@MainActor
enum SourceAppIcons {
    private static var cache: [String: NSImage?] = [:]
    private static let generic: NSImage = NSWorkspace.shared.icon(for: .applicationBundle)

    /// The app's icon, or the generic app icon when there is no app to ask.
    static func icon(forBundleId bundleId: String?) -> NSImage {
        installedIcon(forBundleId: bundleId) ?? generic
    }

    /// The app's icon, or nil when there is none to show: no identifier, or an app no longer on this Mac (FR-003-07).
    static func installedIcon(forBundleId bundleId: String?) -> NSImage? {
        guard let bundleId, !bundleId.isEmpty else { return nil }
        if let cached = cache[bundleId] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleId] = .some(icon)
        return icon
    }
}
