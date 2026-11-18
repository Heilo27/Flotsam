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
    private func ingestWarmed(_ rig: Rig, key: String = "img", width: Int = 1200, height: Int = 800) async throws -> UUID {
        let id = try await rig.create(rig.image(key, TestImage.make(width: width, height: height, format: .png)))
        // `awaitThumbnails` waits on the event (both files written) with a 60 s hang guard, the one home of this wait.
        try #require(await rig.awaitThumbnails(id), "warm-up never wrote both thumbnails")
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

    /// OC-7129. Given three items with warm thumbnails on disk and the middle one's in the memory cache, when the
    /// middle one is deleted, then its thumbnail files are gone, asking for its thumbnail again returns nothing (the
    /// memory cache was evicted too), and both neighbours keep their thumbnails and blobs.
    @Test("OC-7129 delete removes thumbnail files and evicts the cache, both neighbours keep theirs")
    func oc7129_deleteDiscardsThumbnails() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanUp() }
        // given three ingested items, the doomed one in the middle
        let first = try await ingestWarmed(rig, key: "img-1", width: 640, height: 480)
        let doomed = try await ingestWarmed(rig)
        let third = try await ingestWarmed(rig, key: "img-3", width: 800, height: 600)
        let survivors = [first, third]
        let idsBefore = try await rig.store.reader().read { try String.fetchAll($0, sql: "SELECT id FROM item") }
        #expect(Set(idsBefore) == Set([first, doomed, third].map(\.uuidString)), "precondition")
        let blobsBefore = rig.blobFiles().count
        // Prime the memory cache of the instance that will do the deleting.
        _ = await rig.store.database.thumbnail(itemId: doomed, size: .grid)
        _ = await rig.store.database.thumbnail(itemId: doomed, size: .preview)

        // when the middle item is deleted
        let deleted = try await rig.store.database.delete(ids: [doomed]).get()

        // then only the middle item is gone, and the whole remaining set is the two neighbours
        #expect(deleted == [doomed])
        let idsAfter = try await rig.store.reader().read { try String.fetchAll($0, sql: "SELECT id FROM item") }
        #expect(Set(idsAfter) == Set(survivors.map(\.uuidString)))
        #expect(try rig.itemCount() == 2)
        #expect(!rig.store.exists(thumbPath(rig, doomed, 256)))
        #expect(!rig.store.exists(thumbPath(rig, doomed, 512)))
        #expect(await rig.store.database.thumbnail(itemId: doomed, size: .grid) == nil)
        #expect(await rig.store.database.thumbnail(itemId: doomed, size: .preview) == nil)
        for survivor in survivors {
            #expect(rig.store.exists(thumbPath(rig, survivor, 256)), "neighbour 256 thumb")
            #expect(rig.store.exists(thumbPath(rig, survivor, 512)), "neighbour 512 thumb")
        }
        #expect(rig.blobFiles().count == blobsBefore - 1)
    }
}
