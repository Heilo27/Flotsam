import FlotsamBase
import Foundation

/// Representation files on disk (FR-007-04).
///
/// A blob is written to `tmp/`, fsync'd, then atomically renamed into `blobs/<first two of itemId>/<itemId>.<n>`.
/// The database row that references it is committed only after the rename, so a crash can leave an orphan file
/// (reconcile deletes it) but never a row pointing at a half-written file. Blobs are never modified in place and
/// never shared between items.
struct BlobStore: Sendable {
    let folder: DataFolder
    let fileSystem: any FileSystemPort

    /// File name relative to `blobs/`: `<first two of itemId>/<itemId>.<n>`. This is what `representation.blobName` holds.
    static func blobName(itemId: UUID, ordinal: Int) -> String {
        let id = itemId.uuidString
        return "\(id.prefix(2))/\(id).\(ordinal)"
    }

    /// True for exactly `<shard>/<file>` with no empty, `.` or `..` component: what `blobName` always is when this
    /// store wrote it. Deletion checks it so a damaged row cannot point `remove` outside `blobs/`.
    static func isWellFormed(blobName: String) -> Bool {
        let parts = blobName.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// True for a file name `blobName` could have produced: `<uuid>.<ordinal>`. Reconcile deletes unreferenced files
    /// only when they match, so a stray file in `blobs/` that Flotsam did not write is never removed.
    static func isGeneratedFileName(_ file: String) -> Bool {
        let parts = file.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil && Int(parts[1]) != nil
    }

    func url(forBlobName name: String) -> URL { folder.blobsURL.appendingPathComponent(name) }

    func write(_ data: Data, itemId: UUID, ordinal: Int) -> FlotsamResult<String> {
        let name = Self.blobName(itemId: itemId, ordinal: ordinal)
        switch writeAtomically(data, to: url(forBlobName: name)) {
        case .success: return .success(name)
        case .failure(let error): return .failure(error)
        }
    }

    /// tmp, fsync, rename. Also used for thumbnails so a crash never leaves a half-written file that looks valid.
    func writeAtomically(_ data: Data, to destination: URL) -> FlotsamResult<Void> {
        let failure = FlotsamError(.stoIo001, "File could not be written", context: [.byteSize: .bytes(data.count)])
        let staging = folder.tmpURL.appendingPathComponent(UUID().uuidString)
        if case .failure = fileSystem.createDirectory(
            at: destination.deletingLastPathComponent(), permissions: DataFolder.folderPermissions)
        {
            return .failure(failure)
        }
        if case .failure = fileSystem.writeFile(data, to: staging, permissions: DataFolder.filePermissions) {
            _ = fileSystem.removeItem(at: staging)
            return .failure(failure)
        }
        if case .failure = fileSystem.moveItem(at: staging, to: destination) {
            _ = fileSystem.removeItem(at: staging)
            return .failure(failure)
        }
        return .success(())
    }

    func read(blobName: String) -> FlotsamResult<Data> { fileSystem.readFile(at: url(forBlobName: blobName)) }

    /// Removes one blob. A missing file counts as removed: the goal is "not on disk".
    func remove(blobName: String) -> FlotsamResult<Void> {
        let target = url(forBlobName: blobName)
        guard fileSystem.fileExists(at: target) else { return .success(()) }
        return fileSystem.removeItem(at: target)
    }
}
