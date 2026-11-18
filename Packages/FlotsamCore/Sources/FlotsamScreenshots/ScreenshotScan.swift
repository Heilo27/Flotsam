import FlotsamBase
import FlotsamStorage
import Foundation

/// One qualifying screenshot in the watched folder.
public struct ScreenshotFile: Sendable, Equatable {
    public let url: URL
    /// The birth date (FR-002-08, FR-002-09), or the modification date on a volume that records no birth date.
    public let createdAt: Date
    public let byteSize: Int

    public init(url: URL, createdAt: Date, byteSize: Int) {
        self.url = url
        self.createdAt = createdAt
        self.byteSize = byteSize
    }

    /// The one place the date rule lives: birth date, or the modification date when the volume records none.
    public init(url: URL, info: FileInfo) {
        self.init(url: url, createdAt: info.createdAt ?? info.modifiedAt, byteSize: info.byteSize)
    }
}

/// FR-002-16: the one test for "this path is a screenshot file that really lives in the watched folder". A symbolic
/// link is rejected whatever it points at, and so is any file whose resolved location is not a direct child of the
/// folder it was found in. The scanner applies it when listing; the importer applies it again to the settled file,
/// because the file may have been swapped for a link between the two.
enum ScreenshotPathGuard {
    static func accepts(_ url: URL, kind: FileKind) -> Bool {
        guard kind == .regular else { return false }
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return url.resolvingSymlinksInPath().deletingLastPathComponent() == folder
    }
}

/// Lists the qualifying screenshots among the direct children of a folder (FR-002-04, FR-002-06). Subfolders,
/// symbolic links and anything that fails recognition are dropped silently, with no log entry.
public struct ScreenshotFolderScanner: Sendable {
    private let fileSystem: any FileSystemPort
    private let preferences: any ScreenCapturePreferences

    public init(fileSystem: any FileSystemPort, preferences: any ScreenCapturePreferences) {
        self.fileSystem = fileSystem
        self.preferences = preferences
    }

    /// A failed listing is returned as is; the caller decides between `SSP-PRM-001` and a missing folder.
    public func scan(_ folder: URL) -> FlotsamResult<[ScreenshotFile]> {
        let customPrefix = preferences.name()
        return fileSystem.contentsOfDirectory(at: folder).map { urls in
            // Foundation lists /var/... as /private/var/...; a file keeps one path form (the folder's) so the
            // watcher's seen/pending/retry keys agree between a scan and an event for the same file.
            urls.compactMap { candidate(folder.appendingPathComponent($0.lastPathComponent), customPrefix: customPrefix) }
        }
    }

    /// The same test for one path, used when an FSEvents event names a single file.
    public func candidate(_ url: URL) -> ScreenshotFile? {
        candidate(url, customPrefix: preferences.name())
    }

    private func candidate(_ url: URL, customPrefix: String?) -> ScreenshotFile? {
        let name = url.lastPathComponent
        guard ScreenshotRecognizer.hasCandidateName(name) else { return nil }
        guard let info = fileSystem.fileInfo(at: url), ScreenshotPathGuard.accepts(url, kind: info.kind) else { return nil }
        let attribute = fileSystem.extendedAttribute(named: ScreenshotRecognizer.screenCaptureAttribute, at: url)
        guard ScreenshotRecognizer.qualifies(fileName: name, attribute: attribute, customPrefix: customPrefix) else {
            return nil
        }
        return ScreenshotFile(url: url, info: info)
    }
}

/// Which files a scan imports (FR-002-08, FR-002-12). Pure, so the watermark arithmetic is tested without a folder.
public enum ScreenshotSelection {
    /// FR-002-08: a file qualifies when born later than `lastScanAt` minus this slack.
    public static let watermarkSlack: TimeInterval = 5
    /// FR-002-12: backfill never reaches back further than this, even when retention is longer.
    public static let backfillMaxAge: TimeInterval = 30 * 24 * 60 * 60
    /// FR-002-12: backfill imports at most this many files.
    public static let backfillMaxCount = 500

    /// Reconcile scan, oldest first. With no watermark yet (first launch) nothing is imported: older screenshots
    /// come in only through "Import recent screenshots", which onboarding offers (FR-002-12).
    public static func reconcile(_ files: [ScreenshotFile], lastScanAt: Date?) -> [ScreenshotFile] {
        guard let lastScanAt else { return [] }
        let floor = lastScanAt.addingTimeInterval(-watermarkSlack)
        return files.filter { $0.createdAt > floor }.sorted(by: oldestFirst)
    }

    /// "Import recent screenshots": born within the retention window (at most 30 days), the 500 newest, imported
    /// oldest first. Forever retention uses the 30-day cap.
    public static func backfill(_ files: [ScreenshotFile], now: Date, retention: RetentionPreset) -> [ScreenshotFile] {
        let retentionAge = retention.periodMillis.map { TimeInterval($0) / 1000 } ?? backfillMaxAge
        let floor = now.addingTimeInterval(-min(retentionAge, backfillMaxAge))
        let recent = files.filter { $0.createdAt >= floor }.sorted(by: oldestFirst)
        return Array(recent.suffix(backfillMaxCount))
    }

    /// Ties break by path so the order is the same on every run.
    private static func oldestFirst(_ lhs: ScreenshotFile, _ rhs: ScreenshotFile) -> Bool {
        lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.url.path < rhs.url.path
    }
}
