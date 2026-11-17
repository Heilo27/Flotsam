import AppKit
import FlotsamBase

/// `SourceAppPort` over `NSWorkspace` (FR-001-13): the frontmost application and bundle-identifier name look-up.
@MainActor
struct SystemSourceApps: SourceAppPort {
    func frontmostApp() -> SourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleId = app.bundleIdentifier else { return nil }
        return SourceApp(bundleId: bundleId, name: app.localizedName)
    }

    func localizedName(forBundleId bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
