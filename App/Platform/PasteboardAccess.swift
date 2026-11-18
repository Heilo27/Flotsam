import AppKit
import FlotsamBase

/// The "Paste from Other Apps" state, for onboarding guidance only (FR-008-13: never requested programmatically).
/// Reading `accessBehavior` does not trigger the system alert. Every supported macOS (26+) gates pasteboard reads
/// (FRD-001 FR-001-18), so there is no ungated case.
enum PasteboardAccess {
    /// True only when the system reports "Allow". `.default` and `.ask` both mean a read may prompt or be refused.
    static var isAllowed: Bool {
        NSPasteboard.general.accessBehavior == .alwaysAllow
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// `PasteboardAccessPort` over the system setting; capture reads it at launch (FR-001-18 a).
struct SystemPasteboardAccess: PasteboardAccessPort {
    var isReadAllowed: Bool { PasteboardAccess.isAllowed }
}
