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
        return await regenerateThumbnail(itemId: itemId, size: size, url: url, key: key)
    }

    /// Frees what only a visible panel needs (S5: Flotsam idles at under 60 MB): the thumbnail LRU and SQLite's page
    /// caches. The disk thumbnails stay, so the next open reads them back. Call when the Library and Shelf panels close.
    public func releaseMemory() async {
        await thumbnails.removeAll()
        pool.releaseMemory()
    }

    /// Writes both thumbnails of a new image to disk and nowhere else: nobody is looking at it yet, so it must not
    /// sit in the memory LRU (S5). `source` is the stored image, already in memory at ingest, so there is no re-read.
    func writeThumbnails(itemId: UUID, source: Data) async {
        for size in ThumbnailSize.allCases {
            guard let jpeg = await imageWorker.thumbnail(from: source, edge: size.rawValue) else { continue }
            if case .failure(let error) = blobs.writeAtomically(jpeg, to: folder.thumbnailURL(itemId: itemId, edge: size.rawValue)) {
                FlotsamLog.log(error, category: .storage)
            }
        }
    }

    private func regenerateThumbnail(itemId: UUID, size: ThumbnailSize, url: URL, key: String) async -> Data? {
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
              let jpeg = await imageWorker.thumbnail(from: source, edge: size.rawValue)
        else { return nil }
        // Best effort: a failed disk write only means it is rebuilt next time, but it is logged (FRD-000).
        if case .failure(let error) = blobs.writeAtomically(jpeg, to: url) {
            FlotsamLog.log(error, category: .storage)
        }
        await thumbnails.store(jpeg, for: key)
        return jpeg
    }

    /// Drops memory and disk thumbnails for deleted items (FR-007-15).
    func discardThumbnails(itemIds: [UUID]) async {
        for itemId in itemIds {
            await thumbnails.evict(itemId: itemId)
            for size in ThumbnailSize.allCases {
                _ = fileSystem.removeItem(at: folder.thumbnailURL(itemId: itemId, edge: size.rawValue))
            }
        }
    }
}
