import Foundation

/// Which app a copy came from (FR-001-13). Main-actor like the pasteboard port: both read `NSWorkspace` state that
/// must be sampled at the moment the change is detected.
@MainActor
public protocol SourceAppPort {
    /// The frontmost application right now; nil when there is none.
    func frontmostApp() -> SourceApp?
    /// The localized name of an installed app, for a bundle identifier named by `org.nspasteboard.source`.
    func localizedName(forBundleId bundleId: String) -> String?
}
