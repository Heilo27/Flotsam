import AppKit
import FlotsamBase

/// The two system pickers the Settings and onboarding screens share (FR-008-10, FR-008-11), with the validation each
/// FR defines, so no screen restates it. Each returns nil when the user cancels.
@MainActor
enum Pickers {
    /// A screenshot folder (FR-008-10): the system folder picker, then the validation (exists, is a directory, readable
    /// and listable). Failure is SET-VAL-001, shown inline, and the caller leaves the previous value alone. Success is
    /// the security-scoped bookmark, ready to store in `screenshots.folderOverride`.
    static func chooseScreenshotFolder(startingAt start: URL? = nil) -> FlotsamResult<FolderOverride>? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = start
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(FlotsamError(.setVal001, "Chosen screenshot folder is not a directory"))
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            return .success(.bookmark(data))
        } catch {
            return .failure(FlotsamError(.setVal001, "Chosen screenshot folder is not readable", underlying: UnderlyingErrorInfo(error)))
        }
    }

    /// The folder's last path component, for "Screenshot folder: Shots"; nil when there is no override or the bookmark
    /// no longer resolves (the registry reads that as none, AC-008-02).
    static func folderName(of override: FolderOverride) -> String? {
        guard case .bookmark(let data) = override else { return nil }
        var stale = false
        let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        return url?.lastPathComponent
    }

    /// An application, returned as its bundle identifier; a bundle without one is SET-VAL-002 (FR-008-11).
    static func chooseApplicationBundleID() -> FlotsamResult<String>? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let identifier = Bundle(url: url)?.bundleIdentifier else {
            return .failure(FlotsamError(.setVal002, "Picked app has no bundle identifier"))
        }
        return .success(identifier)
    }
}
