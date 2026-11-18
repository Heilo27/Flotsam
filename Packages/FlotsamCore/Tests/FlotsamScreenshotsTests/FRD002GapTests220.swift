import CryptoKit
import FlotsamBase
import Foundation
import Testing
@testable import FlotsamScreenshots
@testable import FlotsamStorage

// TASK-220 (OC-2043, OC-2044, OC-2052, OC-2053; AC-002-08, FR-002-11): an imported screenshot and its original file
// are independent. Real ingest pipeline, real database, real blob and thumbnail files; everything is read back through
// a FRESH database handle (`rig.relaunch()`), which also means a fresh in-memory thumbnail cache.
//
// UNTESTABLE-AT-PACKAGE: the ⌘⌫ keystroke of OC-2044 (a Library UI path). Seam: `FlotsamDatabase.delete(ids:)`, the
// only deletion path (FR-007-15), which the UI calls.
// UNTESTABLE-AT-PACKAGE: "moved to Trash and emptied" of OC-2043. Seam: `FileManager.removeItem` on the original,
// which leaves the same observable state (no file at the path).
// Spec word "thumbnail rows": Flotsam keeps thumbnails as files (`thumbs/<id>-<edge>.jpg`), not rows; no table holds
// them. The tests observe those files and `ThumbnailCache.thumbnail(itemId:size:)`.

private let wide = 600  // wider than the 512 px preview edge, so a thumbnail is a real downscale
private let high = 400

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func size(ofJPEG data: Data?) -> [Int]? {
    data.flatMap { GapImage.pixelSize(of: $0) }.map { [$0.width, $0.height] }
}

/// One imported screenshot: its item id, its original file, the original's SHA-256 at import time.
private struct Shot {
    let id: UUID
    let url: URL
    let sha: String
}

private enum GapSetupError: Error { case noItem }

/// `count` distinct 600x400 screenshots imported through the real watcher into a fresh library.
private func importShots(_ count: Int) async throws -> (rig: RealIngestRig, shots: [Shot]) {
    let mark = Date().addingTimeInterval(-100)
    let rig = try await RealIngestRig.make(watermark: mark)
    var urls: [URL] = []
    for _ in 0..<count { urls.append(try rig.shot(in: rig.desktop, born: mark.addingTimeInterval(30), image: GapImage.make(width: wide, height: high)).url) }
    rig.clock.advance(by: 60)
    await rig.watcher.start()
    guard await rig.waitForItems(count) else { rig.cleanUp(); throw GapSetupError.noItem }
    var idByPath: [String: UUID] = [:]
    for id in try await rig.itemIds() { if let path = try await rig.itemRow(id)?.originalPath { idByPath[path] = id } }
    var shots: [Shot] = []
    for url in urls {
        guard let id = idByPath[url.path] else { rig.cleanUp(); throw GapSetupError.noItem }
        shots.append(Shot(id: id, url: url, sha: try sha256(url)))
    }
    return (rig, shots)
}

/// Both thumbnails of the item as the UI would ask for them, after making sure they are on disk.
private func thumbnails(_ rig: RealIngestRig, _ id: UUID) async -> (grid: Data?, preview: Data?) {
    (await rig.database.thumbnail(itemId: id, size: .grid), await rig.database.thumbnail(itemId: id, size: .preview))
}

private func thumbFiles(_ rig: RealIngestRig, _ id: UUID) -> [URL] {
    ThumbnailSize.allCases.map { rig.database.folder.thumbnailURL(itemId: id, edge: $0.rawValue) }
}

@Suite("FRD-002 gap: original file and item are independent (TASK-220)")
struct OriginalAndItemIndependenceGapTests {
    @Test("TASK-220 OC-2043 OC-2052: deleting the original keeps the item (count delta 0); on a fresh handle its content and both previews keep the same pixel size")
    func deletingOriginalKeepsItemAndPreview() async throws {
        // given an imported 600x400 screenshot, its content and both thumbnails read, and a second item as a witness
        let (rig, shots) = try await importShots(2)
        defer { rig.cleanUp() }
        let (subject, witness) = (shots[0], shots[1])
        let idsBefore = try await rig.itemIds()
        let contentBefore = try await rig.database.content(of: subject.id).get()
        let blobBefore = try #require(contentBefore.representations.first)
        #expect(contentBefore.representations.count == 1)
        #expect(GapImage.pixelSize(of: blobBefore.data)?.width == 600 && GapImage.pixelSize(of: blobBefore.data)?.height == 400)
        let thumbsBefore = await thumbnails(rig, subject.id)
        // (liveness: the preview really is a downscale to the spec'd edges, so "same size" below is not "both nil")
        #expect(size(ofJPEG: thumbsBefore.grid)?.max() == 256)
        #expect(size(ofJPEG: thumbsBefore.preview)?.max() == 512)
        let gridSize = size(ofJPEG: thumbsBefore.grid)
        let previewSize = size(ofJPEG: thumbsBefore.preview)

        // when the original is deleted from disk, then Flotsam reopens the library
        try FileManager.default.removeItem(at: subject.url)
        #expect(!exists(subject.url))
        try await rig.relaunch()

        // then the item is still there: count delta 0, same ids, row still names its original path
        #expect(try await rig.itemCount() == 2)
        #expect(try await rig.itemIds() == idsBefore)
        #expect(try await rig.itemRow(subject.id)?.originalPath == subject.url.path)
        // and its content (kind, bytes, pixel size) is unchanged
        let contentAfter = try await rig.database.content(of: subject.id).get()
        #expect(contentAfter == contentBefore)
        let blobAfter = try #require(contentAfter.representations.first)
        #expect(GapImage.pixelSize(of: blobAfter.data)?.width == 600 && GapImage.pixelSize(of: blobAfter.data)?.height == 400)
        // and both thumbnails still come back with the same pixel size as before
        let thumbsAfter = await thumbnails(rig, subject.id)
        #expect(size(ofJPEG: thumbsAfter.grid) == gridSize)
        #expect(size(ofJPEG: thumbsAfter.preview) == previewSize)
        // and the witness is untouched
        #expect(try await rig.database.content(of: witness.id).get().representations.count == 1)
        #expect(try sha256(witness.url) == witness.sha)
    }

    @Test("TASK-220 OC-2043: with the original gone and the thumbnail files wiped, a fresh handle rebuilds both previews from the stored blob at the same pixel size")
    func previewRebuiltFromBlobNotOriginal() async throws {
        // given an imported screenshot with both thumbnails read
        let (rig, shots) = try await importShots(1)
        defer { rig.cleanUp() }
        let subject = shots[0]
        // The import's warm-up is a detached task that writes both thumbnails. Wait for that event (both files on disk,
        // which is its last write) before wiping, or it can land after the wipe and put the files back (TASK-459). The
        // 60 s is a hang guard only; the wait ends the moment the files exist.
        let warmed = thumbFiles(rig, subject.id)
        try #require(await eventually(timeout: .seconds(60)) { warmed.allSatisfy(exists) }, "warm-up never wrote both thumbnails")
        let before = await thumbnails(rig, subject.id)
        let gridSize = try #require(size(ofJPEG: before.grid))
        let previewSize = try #require(size(ofJPEG: before.preview))
        #expect(thumbFiles(rig, subject.id).allSatisfy(exists), "liveness: the thumbnail files exist before the wipe")
        // when the original is deleted, the thumbnail files are deleted, and Flotsam reopens the library
        try FileManager.default.removeItem(at: subject.url)
        for file in thumbFiles(rig, subject.id) { try FileManager.default.removeItem(at: file) }
        try await rig.relaunch()
        #expect(thumbFiles(rig, subject.id).allSatisfy { !exists($0) })
        // then both previews are produced again, from the blob, at the same size, and written back to disk
        let after = await thumbnails(rig, subject.id)
        #expect(size(ofJPEG: after.grid) == gridSize)
        #expect(size(ofJPEG: after.preview) == previewSize)
        #expect(thumbFiles(rig, subject.id).allSatisfy(exists))
        #expect(try await rig.itemCount() == 1)
    }

    @Test("TASK-220 OC-2044 OC-2053: deleting items removes exactly those items, blobs and thumbnail files; both originals stay with identical SHA-256; the third item survives whole")
    func deletingItemsLeavesOriginalsAlone() async throws {
        // given three imported screenshots, their blobs and thumbnails on disk, and each original's SHA-256 recorded
        let (rig, shots) = try await importShots(3)
        defer { rig.cleanUp() }
        let victims = [shots[0], shots[1]]
        let survivor = shots[2]
        var blobsOf: [UUID: [URL]] = [:]
        for shot in shots {
            blobsOf[shot.id] = try await rig.blobURLs(of: shot.id)
            #expect(blobsOf[shot.id]?.count == 1 && blobsOf[shot.id]?.allSatisfy(exists) == true)
            _ = await thumbnails(rig, shot.id)
            #expect(thumbFiles(rig, shot.id).allSatisfy(exists))
        }
        let survivorContent = try await rig.database.content(of: survivor.id).get()
        let survivorBlobPaths = try await rig.blobURLs(of: survivor.id).map(\.path)
        #expect(try await rig.itemCount() == 3)

        // when two of them are deleted from history, then Flotsam reopens the library
        let removed = try await rig.database.delete(ids: victims.map(\.id)).get()
        #expect(Set(removed) == Set(victims.map(\.id)))
        try await rig.relaunch()
        await letItSettle()

        // then count is -2, the survivor is the only item left, and it is whole
        #expect(try await rig.itemCount() == 1)
        #expect(try await rig.itemIds() == [survivor.id])
        #expect(try await rig.database.content(of: survivor.id).get() == survivorContent)
        #expect(try await rig.blobURLs(of: survivor.id).map(\.path) == survivorBlobPaths)
        #expect(thumbFiles(rig, survivor.id).allSatisfy(exists))
        // and for each deleted item: no item row, no representation rows, no blob file, no thumbnail file, no preview
        for victim in victims {
            #expect(try await rig.itemRow(victim.id) == nil)
            #expect(try await rig.representationCount(of: victim.id) == 0)
            #expect(try await rig.blobURLs(of: victim.id).isEmpty)
            #expect(blobsOf[victim.id]?.allSatisfy { !exists($0) } == true)
            #expect(thumbFiles(rig, victim.id).allSatisfy { !exists($0) })
            #expect(await rig.database.thumbnail(itemId: victim.id, size: .grid) == nil)
            // and the original is still at its path with the same bytes
            #expect(exists(victim.url))
            #expect(try sha256(victim.url) == victim.sha)
        }
        #expect(try sha256(survivor.url) == survivor.sha)
    }

    @Test("TASK-220 OC-2053: deleting an item whose original is already gone succeeds, removes the item and its files, and raises no error")
    func deletingItemAfterOriginalGone() async throws {
        // given an imported screenshot whose original was deleted from disk, and a witness item
        let (rig, shots) = try await importShots(2)
        defer { rig.cleanUp() }
        let (subject, witness) = (shots[0], shots[1])
        let blobs = try await rig.blobURLs(of: subject.id)
        _ = await thumbnails(rig, subject.id)
        try FileManager.default.removeItem(at: subject.url)
        let errorsBefore = await rig.recentErrors().count
        // when the item is deleted from history
        let removed = try await rig.database.delete(ids: [subject.id]).get()
        await letItSettle()
        // then it is gone (count -1) with its blob and thumbnails, the witness remains, and nothing was reported
        #expect(removed == [subject.id])
        #expect(try await rig.itemCount() == 1)
        #expect(try await rig.itemIds() == [witness.id])
        #expect(blobs.count == 1 && blobs.allSatisfy { !exists($0) })
        #expect(thumbFiles(rig, subject.id).allSatisfy { !exists($0) })
        #expect(await rig.recentErrors().count == errorsBefore)
        #expect(try sha256(witness.url) == witness.sha)
    }

    @Test("TASK-220 OC-2044: deleting an id that is not in the library removes nothing: count, survivor, blob and original unchanged")
    func deletingUnknownIdChangesNothing() async throws {
        // given one imported screenshot
        let (rig, shots) = try await importShots(1)
        defer { rig.cleanUp() }
        let subject = shots[0]
        let blobs = try await rig.blobURLs(of: subject.id)
        // when an id that matches no item is deleted
        let removed = try await rig.database.delete(ids: [UUID()]).get()
        // then nothing was removed anywhere
        #expect(removed.isEmpty)
        #expect(try await rig.itemCount() == 1)
        #expect(try await rig.itemIds() == [subject.id])
        #expect(blobs.allSatisfy(exists))
        #expect(try sha256(subject.url) == subject.sha)
    }
}
