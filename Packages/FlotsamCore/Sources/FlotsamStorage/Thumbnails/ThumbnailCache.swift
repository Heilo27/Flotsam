import FlotsamBase
import Foundation
import GRDB

/// The two thumbnail sizes (FR-007-07): the grid cell and the preview pane.
public enum ThumbnailSize: Int, Sendable, CaseIterable {
    case grid = 256
    case preview = 512
}

/// An in-memory LRU over the on-disk thumbnails (FR-007-07), capped at 64 MB of JPEG data.
///
/// Why disk plus memory: the disk copy survives relaunch so scrolling a large library never re-decodes originals;
/// the memory copy keeps a scroll from hitting the disk for every cell. Thumbnails are regenerable, so every
/// failure here degrades to `nil` (the UI shows a placeholder) and never to an error.
actor ThumbnailCache {
    static let memoryCeilingBytes = 64 * 1024 * 1024

    private var entries: [String: Data] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var totalBytes = 0

    func cached(_ key: String) -> Data? {
        guard let data = entries[key] else { return nil }
        touch(key)
        return data
    }

    func store(_ data: Data, for key: String) {
        if let old = entries[key] { totalBytes -= old.count }
        entries[key] = data
        totalBytes += data.count
        touch(key)
        while totalBytes > Self.memoryCeilingBytes, let oldest = order.first {
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { totalBytes -= removed.count }
        }
    }

    /// Runs `work` as one uninterrupted step, serial with every other call on this actor. Thumbnail file writes and
    /// the deletion's file removal both go through here, which is what makes "check the item exists, then write" and
    /// "remove the item's files" unable to interleave (FR-007-15). `work` must not suspend, and it must be short.
    func exclusively<T: Sendable>(_ work: @Sendable (isolated ThumbnailCache) -> T) -> T { work(self) }

    func removeAll() {
        entries = [:]
        order = []
        totalBytes = 0
    }

    func evict(itemId: UUID) {
        for size in ThumbnailSize.allCases { drop(Self.key(itemId, size)) }
    }

    static func key(_ itemId: UUID, _ size: ThumbnailSize) -> String { "\(itemId.uuidString)-\(size.rawValue)" }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func drop(_ key: String) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalBytes -= removed.count
        order.removeAll { $0 == key }
    }
}

extension FlotsamDatabase {
    /// JPEG thumbnail bytes for an item, or nil when there is none to make (not an image, or the blob is missing or
    /// undecodable). Memory, then disk (only a complete JPEG is served), then regenerated from the item's image blob
    /// (FR-007-07): a deleted, emptied or corrupt thumbnail file is rebuilt and rewritten on the next request.
    public func thumbnail(itemId: UUID, size: ThumbnailSize) async -> Data? {
        let key = ThumbnailCache.key(itemId, size)
        if let hit = await thumbnails.cached(key) { return hit }

        let url = folder.thumbnailURL(itemId: itemId, edge: size.rawValue)
        if case .success(let onDisk) = fileSystem.readFile(at: url), await imageWorker.isCompleteJPEG(onDisk) {
            await thumbnails.store(onDisk, for: key)
            return onDisk
        }
        return await regenerateThumbnail(itemId: itemId, size: size, key: key)
    }

    /// Frees what only a visible panel needs (S5: Flotsam idles at under 60 MB): the thumbnail LRU and SQLite's page
    /// caches. The disk thumbnails stay, so the next open reads them back. Call when the Library and Shelf panels close.
    public func releaseMemory() async {
        await thumbnails.removeAll()
        pool.releaseMemory()
    }

    /// Ingest warm-up (S5): writes both thumbnails of a new image to disk and nowhere else, since nobody is looking at
    /// it yet and it must not sit in the memory LRU. `source` is the stored image, already in memory at ingest, so there
    /// is no re-read. Skips a deleted item. A delete that lands while it renders cannot leave an orphan: every write
    /// re-checks the item inside `publishThumbnail`, which is serial with the delete's `discardThumbnails`.
    func warmThumbnails(itemId: UUID, source: Data) async {
        guard itemExists(itemId) else { return }
        await writeThumbnails(itemId: itemId, source: source)
    }

    func writeThumbnails(itemId: UUID, source: Data) async {
        for size in ThumbnailSize.allCases { _ = await renderThumbnail(source, itemId: itemId, size: size, cacheKey: nil) }
    }

    /// Synchronous on purpose: `publishThumbnail` must check and write without a suspension between the two.
    private func itemExists(_ itemId: UUID) -> Bool {
        do {
            return try pool.read { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM item WHERE id = ?)", arguments: [itemId.uuidString]) ?? false
            }
        } catch {
            report(Self.readFailure(error))
            return true  // unknown: keep the thumbnail, it is regenerable and reconcile sweeps orphans
        }
    }

    /// The only way a thumbnail reaches disk or the memory cache. Inside the thumbnail actor's serial section it checks
    /// that the item still exists and then writes, so it cannot interleave with `discardThumbnails` (which removes the
    /// files and the cache entries in the same section, after the delete has committed): either the write sees the
    /// committed delete and does nothing, or it finishes first and the discard removes what it wrote. Returns false
    /// when the item is gone. `cacheKey` also puts the bytes in the memory LRU (a panel asked for them); nil is the
    /// disk-only warm-up. A failed disk write is only logged: the thumbnail is rebuilt next time (FRD-000).
    private func publishThumbnail(_ jpeg: Data, itemId: UUID, size: ThumbnailSize, cacheKey: String?) async -> Bool {
        let url = folder.thumbnailURL(itemId: itemId, edge: size.rawValue)
        let outcome: FlotsamResult<Void>? = await thumbnails.exclusively { cache in
            guard itemExists(itemId) else { return nil }
            let written = blobs.writeAtomically(jpeg, to: url)
            if let cacheKey { cache.store(jpeg, for: cacheKey) }
            return written
        }
        guard let outcome else { return false }
        if case .failure(let error) = outcome { report(error) }
        return true
    }

    /// The one place a thumbnail is rendered and published: JPEG from `source`, then `publishThumbnail`. Nil when the
    /// source does not decode or the item was deleted meanwhile.
    private func renderThumbnail(_ source: Data, itemId: UUID, size: ThumbnailSize, cacheKey: String?) async -> Data? {
        guard let jpeg = await imageWorker.thumbnail(from: source, edge: size.rawValue) else { return nil }
        guard await publishThumbnail(jpeg, itemId: itemId, size: size, cacheKey: cacheKey) else { return nil }
        return jpeg
    }

    private func regenerateThumbnail(itemId: UUID, size: ThumbnailSize, key: String) async -> Data? {
        let blobName: String?
        do {
            // The lowest ordinal is the item's primary representation (FR-007-04).
            blobName = try await pool.read { db in
                try String.fetchOne(
                    db, sql: "SELECT blobName FROM representation WHERE itemId = ? ORDER BY id LIMIT 1",
                    arguments: [itemId.uuidString])
            }
        } catch { return nil }
        guard let blobName, case .success(let source) = blobs.read(blobName: blobName),
              let jpeg = await renderThumbnail(source, itemId: itemId, size: size, cacheKey: key)
        else { return nil }
        return jpeg
    }

    /// Drops memory and disk thumbnails for deleted items (FR-007-15). Call it after the delete has committed: it is
    /// serial with `publishThumbnail`, so no write can put a file back afterwards.
    func discardThumbnails(itemIds: [UUID]) async {
        for itemId in itemIds {
            let urls = ThumbnailSize.allCases.map { folder.thumbnailURL(itemId: itemId, edge: $0.rawValue) }
            await thumbnails.exclusively { cache in
                cache.evict(itemId: itemId)
                for url in urls { _ = fileSystem.removeItem(at: url) }
            }
        }
    }
}
