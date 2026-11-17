import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage

// FRD-007 8T batch 2, thumbnails (FR-007-07, FR-007-15). Thumbnails are read through a SECOND FlotsamDatabase opened
// on the same folder, so its in-memory cache is empty and the answer can only come from the file on disk or from a
// regeneration, never from the first instance's memory.

@Suite struct ThumbnailTests {
    enum Damage: String, CaseIterable, Sendable {
        case deleted, emptied, randomBytes, truncatedJPEG
    }

    private func thumbPath(_ rig: Rig, _ id: UUID, _ edge: Int) -> URL {
        rig.store.thumbsDir.appendingPathComponent("\(id.uuidString)-\(edge).jpg")
    }

    /// Ingests a 1200x800 PNG and waits for the post-commit warm-up to put both thumbnails on disk.
    private func ingestWarmed(_ rig: Rig) async throws -> UUID {
        let id = try await rig.create(rig.image("img", TestImage.make(width: 1200, height: 800, format: .png)))
        let warmed = await waitUntil { rig.store.exists(thumbPath(rig, id, 256)) && rig.store.exists(thumbPath(rig, id, 512)) }
        try #require(warmed, "warm-up never wrote both thumbnails")
        return id
    }

    private func freshDatabase(_ rig: Rig) async throws -> FlotsamDatabase {
        try await FlotsamDatabase.open(folder: rig.store.root, fileSystem: LocalFileSystem(), clock: rig.store.clock).get()
    }

    /// OC-7044. Given an image item whose grid thumbnail file is damaged (deleted, emptied, overwritten with random
    /// bytes, or cut in half), when a fresh database instance is asked for the thumbnail, then it returns a valid JPEG
    /// whose longest edge is 256, with no error, and the file on disk is valid again. Goes red if a non-empty damaged
    /// file is served as it is (the cache trusts any non-empty file).
    @Test("OC-7044 damaged thumbnail is regenerated, never served", arguments: Damage.allCases)
    func oc7044_damagedThumbnailIsRegenerated(_ damage: Damage) async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let id = try await ingestWarmed(rig)
        let url = thumbPath(rig, id, 256)
        let valid = try Data(contentsOf: url)
        switch damage {
        case .deleted: try FileManager.default.removeItem(at: url)
        case .emptied: try Data().write(to: url)
        case .randomBytes: try Data((0..<2048).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        case .truncatedJPEG: try valid.prefix(valid.count / 2).write(to: url)
        }

        let damaged = try? Data(contentsOf: url)
        let fresh = try await freshDatabase(rig)
        let served = await fresh.thumbnail(itemId: id, size: .grid)

        #expect(served != nil)
        #expect(served != damaged, "the damaged bytes were served as the thumbnail")
        let info = served.flatMap(TestImage.inspect)
        #expect(info?.type == "public.jpeg")
        #expect(info?.width == 256)
        #expect((170...171).contains(info?.height ?? 0))
        let onDisk = try? Data(contentsOf: url)
        #expect(onDisk.flatMap(TestImage.inspect)?.type == "public.jpeg")
        #expect(try rig.itemCount() == 1)
    }

    /// OC-7045. Given a 1200x800 image, when the preview thumbnail is requested from a fresh instance, then a JPEG
    /// whose longest edge is 512 is returned and `thumbs/<id>-512.jpg` holds the same bytes.
    @Test("OC-7045 preview thumbnail is a 512 JPEG on disk")
    func oc7045_previewThumbnail() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let id = try await ingestWarmed(rig)

        let fresh = try await freshDatabase(rig)
        let served = try #require(await fresh.thumbnail(itemId: id, size: .preview))

        let info = TestImage.inspect(served)
        #expect(info?.type == "public.jpeg")
        #expect(info?.width == 512)
        #expect((340...342).contains(info?.height ?? 0))
        #expect(try Data(contentsOf: thumbPath(rig, id, 512)) == served)
    }

    /// OC-7129. Given two items with warm thumbnails in the memory cache and on disk, when one is deleted, then its
    /// thumbnail files are gone, asking for its thumbnail again returns nothing (the memory cache was evicted too),
    /// and the other item's thumbnails are untouched.
    @Test("OC-7129 delete removes thumbnail files and evicts the cache, survivor keeps both")
    func oc7129_deleteDiscardsThumbnails() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        let doomed = try await ingestWarmed(rig)
        let survivor = try await rig.create(rig.image("img-2", TestImage.make(width: 640, height: 480, format: .png)))
        let warmed = await waitUntil { rig.store.exists(thumbPath(rig, survivor, 256)) && rig.store.exists(thumbPath(rig, survivor, 512)) }
        try #require(warmed)
        // Prime the memory cache of the instance that will do the deleting.
        _ = await rig.store.database.thumbnail(itemId: doomed, size: .grid)
        _ = await rig.store.database.thumbnail(itemId: doomed, size: .preview)

        let deleted = try await rig.store.database.delete(ids: [doomed]).get()

        #expect(deleted == [doomed])
        #expect(try rig.itemCount() == 1)
        #expect(!rig.store.exists(thumbPath(rig, doomed, 256)))
        #expect(!rig.store.exists(thumbPath(rig, doomed, 512)))
        #expect(await rig.store.database.thumbnail(itemId: doomed, size: .grid) == nil)
        #expect(await rig.store.database.thumbnail(itemId: doomed, size: .preview) == nil)
        #expect(rig.store.exists(thumbPath(rig, survivor, 256)))
        #expect(rig.store.exists(thumbPath(rig, survivor, 512)))
        #expect(rig.blobFiles().count == 1)
    }
}
