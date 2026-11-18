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

    /// Name of the pre-migration copy of a version-`fromVersion` database (FR-007-17).
    static func preMigrationCopyName(fromVersion: Int) -> String { "flotsam-v\(fromVersion).sqlite" }

    /// True only for a file Flotsam itself writes into `pre-migration/`: exactly `flotsam-v<int>.sqlite`, or that name
    /// plus `-wal` / `-shm`. Pruning deletes through this test alone, so anything else a user or another tool put in
    /// the folder is never touched (FR-007-17, decision 6). Digits are ASCII-only and must parse as an `Int`, so
    /// `flotsam-v1.sqlite.bak` or `flotsam-vx.sqlite` do not match.
    static func isPreMigrationCopyFile(named name: String) -> Bool {
        var stem = Substring(name)
        for suffix in ["-wal", "-shm"] where stem.hasSuffix(suffix) {
            stem = stem.dropLast(suffix.count)
            break
        }
        guard stem.hasPrefix("flotsam-v"), stem.hasSuffix(".sqlite") else { return false }
        let digits = stem.dropFirst("flotsam-v".count).dropLast(".sqlite".count)
        return digits.allSatisfy { ("0"..."9").contains($0) } && Int(digits) != nil
    }

    /// Creates the folder and its subfolders (0700) and empties `tmp/`, whose contents are in-flight writes from a
    /// previous run that can never complete (FR-007-01). Failure is `STO-IO-002`, a Fatal (the app cannot run).
    func prepare(fileSystem: any FileSystemPort) -> FlotsamResult<Void> {
        for folder in [root, blobsURL, thumbsURL, tmpURL] {
            if case .failure = fileSystem.createDirectory(at: folder, permissions: Self.folderPermissions) {
                return .failure(FlotsamError(.stoIo002, "Data folder could not be created"))
            }
            // `createDirectory` applies its mode only to a folder it creates, so a folder an earlier build (or the
            // user) left looser is tightened here, every launch (FR-007-01).
            guard Self.enforceMode(Self.folderPermissions, at: folder) else {
                return .failure(FlotsamError(.stoIo002, "Data folder permissions could not be restricted"))
            }
        }
        // Folders Flotsam created in earlier launches: same rule, and only if they exist (they are made on demand).
        for folder in [preMigrationURL] + existingQuarantineFolders(fileSystem: fileSystem)
        where FileManager.default.fileExists(atPath: folder.path) {
            guard Self.enforceMode(Self.folderPermissions, at: folder) else {
                return .failure(FlotsamError(.stoIo002, "Data folder permissions could not be restricted"))
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

    /// Sets `mode` on an existing path. True when the mode is in force afterwards (including "already was").
    @discardableResult
    private static func enforceMode(_ mode: Int, at url: URL) -> Bool {
        let current = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? nil
        if current == mode { return true }
        do {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Makes the database files owner-only BEFORE the pool opens them (FR-007-01, FR-007-02). SQLite creates `-wal`
    /// and `-shm` with the mode of the main database file, ignoring the umask, so a main file that is already 0600
    /// makes all three 0600 from the moment each exists. A missing main file is created empty (0600); a zero-byte
    /// `flotsam.sqlite` is a new empty library, not damage (FR-007-13). Existing files written by an earlier build with
    /// the process umask (0644) are tightened here, before SQLite touches them. Failure is `STO-IO-002`.
    func prepareDatabaseFiles(fileSystem: any FileSystemPort) -> FlotsamResult<Void> {
        if !fileSystem.fileExists(at: databaseURL),
            case .failure = fileSystem.writeFile(Data(), to: databaseURL, permissions: Self.filePermissions)
        {
            return .failure(FlotsamError(.stoIo002, "Database file could not be created"))
        }
        for url in databaseFileURLs where FileManager.default.fileExists(atPath: url.path) {
            guard Self.enforceMode(Self.filePermissions, at: url) else {
                return .failure(FlotsamError(.stoIo002, "Database file permissions could not be restricted"))
            }
        }
        return .success(())
    }

    /// Thumbnail file for an item at one size (FR-007-07): `thumbs/<itemId>-<size>.jpg`.
    func thumbnailURL(itemId: UUID, edge: Int) -> URL {
        thumbsURL.appendingPathComponent("\(itemId.uuidString)-\(edge).jpg")
    }
}
