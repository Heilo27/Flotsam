import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// TASK-459 blind QA (Worf). The builder's `lateWarmUpWriteAfterDeleteLeavesNothing` calls the write AFTER the delete has
// finished, so the item-exists re-check alone satisfies it: it stays green with the `exclusively` section removed. This
// suite holds a thumbnail write mid-flight (after its exists-check, inside the staging write) while a delete runs, which is
// the interleaving the FRD-007 FR-007-15 sentence forbids.

/// Local file system that parks the first thumbnail staging write until released.
private final class ParkingFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var armedFolder: URL?
    private var parkedFlag = false

    func arm(stagingFolder: URL) { lock.withLock { armedFolder = stagingFolder; parkedFlag = false } }
    var parked: Bool { lock.withLock { parkedFlag } }
    func open() { release.signal() }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with source: URL) -> FlotsamResult<Void> { real.replaceItem(at: destination, with: source) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { real.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> {
        let shouldPark: Bool = lock.withLock {
            guard let armedFolder, !parkedFlag, url.deletingLastPathComponent().path == armedFolder.path else { return false }
            parkedFlag = true
            return true
        }
        if shouldPark { release.wait() }
        return real.writeFile(data, to: url, permissions: permissions)
    }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { real.readFileNoFollow(at: url) }
    func fileInfo(at url: URL) -> FileInfo? { real.fileInfo(at: url) }
    func availableCapacity(at url: URL) -> Int64? { real.availableCapacity(at: url) }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@Suite struct ThumbnailPublishInterleavingWorfTests {
    /// Given a thumbnail regeneration parked after it checked the item exists (its staging write has not finished), when
    /// the item is deleted and then the write is allowed to finish, then no thumbnail file for the deleted item remains.
    /// Goes red if the exists-check and the write do not run in the same serial section as `discardThumbnails` (the
    /// delete then completes while the write is parked, and the write lands afterwards).
    /// OC: FR-007-15 / AC-007-13 "a thumbnail render that finishes after the delete writes no file".
    @Test("FR-007-15 a write parked after its exists-check cannot land after the delete")
    func parkedWriteCannotResurrectDeletedThumbnail() async throws {
        let fileSystem = ParkingFileSystem()
        let rig = try await Rig.make(on: fileSystem)
        defer { rig.cleanUp() }
        let source = TestImage.make(width: 1200, height: 800, format: .png)
        let id = try await rig.create(rig.image("parked-write", source))
        try #require(await rig.awaitThumbnails(id), "warm-up never wrote both thumbnails")
        fileSystem.arm(stagingFolder: DataFolder(root: rig.store.root).tmpURL)

        let database = rig.store.database
        let writer = Task { await database.writeThumbnails(itemId: id, source: source) }
        try #require(await waitUntil(seconds: 60) { fileSystem.parked }, "the regeneration never reached its staging write")

        let deleted = Flag()
        let deleter = Task { _ = await database.delete(ids: [id]); deleted.set() }
        // Correct code makes the delete wait for the parked write; the bounded wait then opens the gate so nothing hangs.
        _ = await waitUntil(seconds: 3) { deleted.isSet }
        fileSystem.open()
        await writer.value
        await deleter.value

        let thumbs = ThumbnailSize.allCases.map { rig.store.thumbsDir.appendingPathComponent("\(id.uuidString)-\($0.rawValue).jpg") }
        #expect(thumbs.filter { FileManager.default.fileExists(atPath: $0.path) }.isEmpty, "a thumbnail for the deleted item is on disk")
        #expect(try rig.itemCount() == 0)
        #expect(await database.thumbnail(itemId: id, size: .grid) == nil)
    }
}

@Suite struct ReplaceItemFirstWriteWorfTests {
    /// Given a destination that does not exist (the first write of a thumbnail), when `writeAtomically` publishes, then the
    /// file appears with the new bytes and mode 0600, staging is gone; and a failing replace leaves the old file intact.
    /// OC: FR-007-04. Goes red if `replaceItem` demands an existing destination, or loses the staged file's mode.
    @Test("FR-007-04 first write to a missing destination, and a failed replace keeps the old file")
    func firstWriteAndFailedReplace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-459w-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalFileSystem()
        let folder = DataFolder(root: root)
        for dir in [root, folder.thumbsURL, folder.tmpURL] {
            try #require(fileSystem.createDirectory(at: dir, permissions: DataFolder.folderPermissions).isSuccess)
        }
        let store = BlobStore(folder: folder, fileSystem: fileSystem)
        let fresh = folder.thumbsURL.appendingPathComponent("\(UUID().uuidString)-256.jpg")

        let first = store.writeAtomically(Data("first".utf8), to: fresh)

        #expect(first.isSuccess)
        #expect(try Data(contentsOf: fresh) == Data("first".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: fresh.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.tmpURL.path).isEmpty)

        // A destination that is a non-empty directory cannot be replaced by a file: rename fails, the directory survives.
        let blocked = folder.thumbsURL.appendingPathComponent("\(UUID().uuidString)-512.jpg")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: blocked.appendingPathComponent("inner"))
        let second = store.writeAtomically(Data("second".utf8), to: blocked)

        #expect(!second.isSuccess)
        #expect(try Data(contentsOf: blocked.appendingPathComponent("inner")) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.tmpURL.path).isEmpty, "staging left behind")
    }
}
