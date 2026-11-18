import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-459. FRD002GapTests220 "thumbnails remain after delete" failed intermittently (lines 164, 171-172, 198). Two
// product races sat behind it, and these tests pin each one without timing: neither relies on a sleep or on winning a
// race, they call the racing step directly at the moment the race would have lost.

/// The local file system, recording every path `removeItem` is asked to remove. `replaceItem` goes to the real one.
final class RemovalRecordingFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private var removed: [String] = []

    var removedPaths: [String] { lock.withLock { removed } }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with source: URL) -> FlotsamResult<Void> { real.replaceItem(at: destination, with: source) }
    func removeItem(at url: URL) -> FlotsamResult<Void> {
        lock.withLock { removed.append(url.path) }
        return real.removeItem(at: url)
    }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { real.writeFile(data, to: url, permissions: permissions) }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { real.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { real.availableCapacity(at: url) }
}

@Suite struct ThumbnailDeleteRaceTests {
    private func thumbPath(_ rig: Rig, _ id: UUID, _ edge: Int) -> URL {
        rig.store.thumbsDir.appendingPathComponent("\(id.uuidString)-\(edge).jpg")
    }

    /// Given an image whose ingest warm-up is still rendering when the delete commits and discards, when the render
    /// finishes and tries to write, then it writes nothing: no thumbnail file and no cache entry for a deleted item.
    /// The late write is the warm-up's, called here directly after the delete (the exact ordering the flake hit). Goes
    /// red if a thumbnail write does not re-check the item inside the section the discard runs in.
    @Test("FR-007-15 a thumbnail render that finishes after the delete writes nothing")
    func lateWarmUpWriteAfterDeleteLeavesNothing() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let source = TestImage.make(width: 1200, height: 800, format: .png)
        let id = try await rig.create(rig.image("late-write", source))
        try #require(await rig.awaitThumbnails(id), "warm-up never wrote both thumbnails")
        _ = try await rig.store.database.delete(ids: [id]).get()
        try #require(!rig.store.exists(thumbPath(rig, id, 256)), "precondition: delete removed the thumbnail")

        await rig.store.database.writeThumbnails(itemId: id, source: source)

        #expect(!rig.store.exists(thumbPath(rig, id, 256)), "a late write put the 256 thumbnail back")
        #expect(!rig.store.exists(thumbPath(rig, id, 512)), "a late write put the 512 thumbnail back")
        #expect(await rig.store.database.thumbnail(itemId: id, size: .grid) == nil)
    }

    /// Given a thumbnail already on disk, when it is written again, then the old file is replaced by one rename and the
    /// destination is never removed first (a reader between remove and move would find no thumbnail at all). Goes red
    /// if `writeAtomically` removes the destination before moving the new file in.
    @Test("FR-007-04 replacing a file never removes the destination first")
    func replaceNeverRemovesDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-459-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = RemovalRecordingFileSystem()
        let folder = DataFolder(root: root)
        for dir in [root, folder.thumbsURL, folder.tmpURL] {
            try #require(fileSystem.createDirectory(at: dir, permissions: DataFolder.folderPermissions).isSuccess)
        }
        let store = BlobStore(folder: folder, fileSystem: fileSystem)
        let destination = folder.thumbsURL.appendingPathComponent("\(UUID().uuidString)-256.jpg")
        try Data("old".utf8).write(to: destination)

        let result = store.writeAtomically(Data("new".utf8), to: destination)

        #expect(result.isSuccess)
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(!fileSystem.removedPaths.contains(destination.path), "the destination was removed before the new file moved in")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.tmpURL.path).isEmpty, "staging file left behind")
    }
}
