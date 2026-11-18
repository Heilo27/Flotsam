import FlotsamBase
import Foundation

/// Where pickup watches, after FR-002-01 resolution.
public enum ScreenshotLocation: Sendable, Equatable {
    /// The override, or the system `location`, is a usable folder.
    case watching(URL)
    /// The system `location` is set but unusable, so macOS itself saves to the Desktop: watch it, `SSP-IO-001`.
    case usingDesktop(URL)
    /// The override is unusable: pickup is paused (`SSP-IO-003`) and never falls through to the system location.
    case paused

    /// The folder to watch; nil while paused.
    public var folder: URL? {
        switch self {
        case .watching(let url), .usingDesktop(let url): url
        case .paused: nil
        }
    }

    /// The warning this state raises, if any.
    public var warning: ErrorCode? {
        switch self {
        case .watching: nil
        case .usingDesktop: .sspIo001
        case .paused: .sspIo003
        }
    }
}

/// FR-002-01 location resolution, first match wins: (1) the user override; (2) the system `location`; (3) `~/Desktop`.
public struct ScreenshotLocationResolver: Sendable {
    private let fileSystem: any FileSystemPort
    private let preferences: any ScreenCapturePreferences
    private let home: URL

    public init(fileSystem: any FileSystemPort, preferences: any ScreenCapturePreferences, home: URL) {
        self.fileSystem = fileSystem
        self.preferences = preferences
        self.home = home
    }

    public var desktop: URL { home.appendingPathComponent("Desktop", isDirectory: true) }

    /// - Parameter override: the `screenshots.folderOverride` folder, nil when the user has not set one.
    public func resolve(override: URL?) -> ScreenshotLocation {
        if let override {
            let folder = Self.real(override)
            return isUsable(folder) ? .watching(folder) : .paused
        }
        guard let location = preferences.location() else { return .watching(Self.real(desktop)) }
        let systemFolder = Self.real(expanded(location))
        return isUsable(systemFolder) ? .watching(systemFolder) : .usingDesktop(Self.real(desktop))
    }

    /// Symbolic links resolved, so the watcher, the listing and the "did the folder change?" comparison of FR-002-02
    /// all see the folder itself (the user may point `location` at a link).
    static func real(_ folder: URL) -> URL { folder.standardizedFileURL.resolvingSymlinksInPath() }

    /// `~` and `~/…` expand against `home`; anything else is taken as an absolute path.
    func expanded(_ location: String) -> URL {
        if location == "~" { return home }
        if location.hasPrefix("~/") { return home.appendingPathComponent(String(location.dropFirst(2)), isDirectory: true) }
        return URL(fileURLWithPath: location, isDirectory: true).standardizedFileURL
    }

    /// Exists, is a directory and is listable. A listing refused for permission still counts as usable: that is
    /// FR-002-03's `SSP-PRM-001`, raised by the watcher when it lists, not a reason to watch a different folder.
    func isUsable(_ folder: URL) -> Bool {
        guard fileSystem.fileInfo(at: folder)?.kind == .directory else { return false }
        switch fileSystem.contentsOfDirectory(at: folder) {
        case .success: return true
        case .failure(let error): return ScreenshotFolderAccess.isPermissionDenied(error)
        }
    }
}

/// The one test for "listing failed because the user has not granted folder access" (FR-002-03).
public enum ScreenshotFolderAccess {
    public static func isPermissionDenied(_ error: FlotsamError) -> Bool {
        guard let underlying = error.underlying else { return false }
        switch underlying.domain {
        case NSCocoaErrorDomain: return underlying.code == NSFileReadNoPermissionError
        case NSPOSIXErrorDomain: return underlying.code == Int(EPERM) || underlying.code == Int(EACCES)
        default: return false
        }
    }
}
