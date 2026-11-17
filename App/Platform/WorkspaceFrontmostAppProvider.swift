import AppKit
import FlotsamBase

/// The frontmost application according to `NSWorkspace` (FR-003-02, FR-003-15 step 6).
@MainActor
struct WorkspaceFrontmostAppProvider: FrontmostAppProvider {
    func frontmost() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApp(bundleId: app.bundleIdentifier, processId: app.processIdentifier)
    }
}
