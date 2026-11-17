import FlotsamBase
import Foundation

/// The data folder layout (FR-007-01). The one place that knows folder and file names; everything else asks here.
/// The root is injected so tests use a temp directory and the app passes `~/Library/Application Support/Flotsam`.
public struct DataFolder: Sendable {
    public static let folderPermissions = 0o700
    public static let filePermissions = 0o600

    public let root: URL

    public init(root: URL) { self.root = root }

    public var databaseURL: URL { root.appendingPathComponent("flotsam.sqlite") }
    public var blobsURL: URL { root.appendingPathComponent("blobs") }
    public var thumbsURL: URL { root.appendingPathComponent("thumbs") }
    public var tmpURL: URL { root.appendingPathComponent("tmp") }
    public var preMigrationURL: URL { root.appendingPathComponent("pre-migration") }

    /// `flotsam.sqlite` plus the WAL and shared-memory files SQLite keeps beside it.
    var databaseFileURLs: [URL] {
        ["", "-wal", "-shm"].map { root.appendingPathComponent("flotsam.sqlite" + $0) }
    }

    /// Creates the folder and its subfolders (0700) and empties `tmp/`, whose contents are in-flight writes from a
    /// previous run that can never complete (FR-007-01). Failure is `STO-IO-002`, a Fatal (the app cannot run).
    func prepare(fileSystem: any FileSystemPort) -> FlotsamResult<Void> {
        for folder in [root, blobsURL, thumbsURL, tmpURL] {
            if case .failure = fileSystem.createDirectory(at: folder, permissions: Self.folderPermissions) {
                return .failure(FlotsamError(.stoIo002, "Data folder could not be created"))
            }
        }
        // Thumbnails are regenerable, so they are kept out of backups (FR-007-01). Best effort: a volume that cannot
        // honour the flag only makes the backup bigger.
        var thumbs = thumbsURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? thumbs.setResourceValues(values)
        if case .success(let leftovers) = fileSystem.contentsOfDirectory(at: tmpURL) {
            for url in leftovers { _ = fileSystem.removeItem(at: url) }
        }
        return .success(())
    }

    /// Database files are owner-only like the folder (FR-007-01). SQLite creates them with the process umask.
    func restrictDatabaseFilePermissions() {
        for url in databaseFileURLs where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.posixPermissions: Self.filePermissions], ofItemAtPath: url.path)
        }
    }

    /// Thumbnail file for an item at one size (FR-007-07): `thumbs/<itemId>-<size>.jpg`.
    func thumbnailURL(itemId: UUID, edge: Int) -> URL {
        thumbsURL.appendingPathComponent("\(itemId.uuidString)-\(edge).jpg")
    }
}
