import FlotsamBase
import Foundation
import GRDB

/// The only way an item is created or bumped (FR-007-05). One serial actor, so ingest never contends with itself
/// for the image worker or the disk, and the whole pipeline has a single place to read.
///
/// Order: (1) look up `contentKey` and bump on a match; (2) prepare the payload (limits, disk guard, image pipeline);
/// (3) write blobs; (4) insert item, representations, members and `searchText` in one transaction that first
/// re-checks `contentKey`; (5) after commit, publish `itemsChanged`.
///
/// Why the second look-up: this actor suspends at every `await`, so two identical payloads can both pass step 1
/// before either inserts. The in-transaction re-check is what makes "submitted twice concurrently" create one item
/// with `copyCount` 2 (AC-007-04); the loser deletes its freshly written blobs and reports `bumped`.
public actor IngestActor {
    private let database: FlotsamDatabase
    private let settings: SettingsStore

    /// `settings` supplies the image-quality preset (FR-007-08).
    public init(database: FlotsamDatabase, settings: SettingsStore) {
        self.database = database
        self.settings = settings
    }

    public func ingest(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult> {
        // `@Sendable` because `measure` is @concurrent: the closure may not capture actor-isolated state implicitly.
        await FlotsamSignpost.measure("capture.persist") { @Sendable in await self.persist(candidate) }
    }

    // MARK: Pipeline

    private func persist(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult> {
        let occurredAt = candidate.occurredAt.epochMillis

        switch await bumpIfKnown(contentKey: candidate.contentKey, occurredAt: occurredAt) {
        case .failure(let error): return .failure(error)
        case .success(let id?): return bumped(id, warnings: [])
        case .success(nil): break
        }

        let prepared: PreparedItem
        switch await prepare(candidate) {
        case .failure(let error): return .failure(error)
        case .success(let value): prepared = value
        }

        let itemId = UUID()
        let stored: [StoredRepresentation]
        switch writeBlobs(prepared.representations, itemId: itemId) {
        case .failure(let error): return .failure(error)
        case .success(let value): stored = value
        }

        let inserted: Inserted
        do {
            inserted = try await database.pool.write { [candidate, prepared, stored] db in
                // Re-check: see the type documentation for why step 1 alone is not enough.
                if let existing = try Self.lookup(db, contentKey: candidate.contentKey) {
                    try Self.bump(db, id: existing.id, occurredAt: occurredAt)
                    return .raced(existing.id)
                }
                try Self.insert(db, itemId: itemId, candidate: candidate, prepared: prepared, stored: stored)
                return .created
            }
        } catch {
            removeBlobs(stored)
            return .failure(FlotsamDatabase.writeFailure(error))
        }

        switch inserted {
        case .raced(let existingId):
            removeBlobs(stored)
            return bumped(existingId, warnings: prepared.warnings)
        case .created:
            database.events.publish(.itemsChanged)
            var warnings = prepared.warnings
            if prepared.pixelWidth != nil {
                warmThumbnails(itemId, source: prepared.representations[0].data)
                warnings += await enforceBudget(protecting: itemId)
            }
            return .success(IngestResult(outcome: .created(itemId), warnings: warnings))
        }
    }

    // MARK: Step 1 and the re-check

    private func bumpIfKnown(contentKey: String, occurredAt: Int64) async -> FlotsamResult<String?> {
        do {
            return .success(try await database.pool.write { db in
                guard let existing = try Self.lookup(db, contentKey: contentKey) else { return nil }
                try Self.bump(db, id: existing.id, occurredAt: occurredAt)
                return existing.id
            })
        } catch {
            return .failure(FlotsamDatabase.writeFailure(error))
        }
    }

    private func bumped(_ id: String, warnings: [FlotsamError]) -> FlotsamResult<IngestResult> {
        guard let uuid = UUID(uuidString: id) else {
            return .failure(FlotsamError(.stoDb004, "Stored item id is not a UUID"))
        }
        database.events.publish(.itemsChanged)
        return .success(IngestResult(outcome: .bumped(uuid), warnings: warnings))
    }

    /// The most recently copied item with this key. `contentKey` is not unique (FR-007-03), so a key that already
    /// has several rows bumps the newest one.
    private static func lookup(_ db: Database, contentKey: String) throws -> (id: String, lastCopiedAt: Int64)? {
        try Row.fetchOne(
            db, sql: "SELECT id, lastCopiedAt FROM item WHERE contentKey = ? ORDER BY lastCopiedAt DESC LIMIT 1",
            arguments: [contentKey]
        ).map { (id: $0["id"], lastCopiedAt: $0["lastCopiedAt"]) }
    }

    /// `lastCopiedAt` never moves backwards: a screenshot picked up late carries its file date, which may be older
    /// than a copy of the same bytes made since (FR-007-05).
    private static func bump(_ db: Database, id: String, occurredAt: Int64) throws {
        try db.execute(
            sql: "UPDATE item SET lastCopiedAt = max(lastCopiedAt, ?), copyCount = copyCount + 1 WHERE id = ?",
            arguments: [occurredAt, id])
    }

    // MARK: Step 2

    /// Limits (FR-007-06), the disk guard (FR-007-14), then the image pipeline (FR-007-07). The guard runs before the
    /// image decode so a full disk costs no CPU, and before any blob is written.
    private func prepare(_ candidate: IngestCandidate) async -> FlotsamResult<PreparedItem> {
        let limited: LimitedPayload
        switch IngestLimits.apply(to: candidate) {
        case .failure(let error): return .failure(error)
        case .success(let value): limited = value
        }
        let available = database.fileSystem.availableCapacity(at: database.folder.root)
        if let refusal = DiskGuard.check(kind: candidate.kind, available: available) { return .failure(refusal) }
        guard candidate.kind == .image || candidate.kind == .screenshot,
              let primary = limited.representations.first
        else {
            return .success(PreparedItem(
                representations: limited.representations, members: limited.members,
                pixelWidth: nil, pixelHeight: nil, warnings: limited.warnings))
        }

        let quality = settings.value(SettingKeys.storageImageQuality)
        guard let image = await database.imageWorker.process(primary.data, receivedUTI: primary.uti, quality: quality) else {
            // Undecodable bytes are never stored (FR-007-07): the code depends on where they came from.
            let code: ErrorCode = candidate.origin == .screenshotFile ? .sspVal001 : .capVal001
            return .failure(FlotsamError(code, "Image data could not be decoded"))
        }
        var representations = limited.representations
        representations[0] = PasteboardRepresentation(uti: image.uti, data: image.data)
        return .success(PreparedItem(
            representations: representations, members: limited.members,
            pixelWidth: image.width, pixelHeight: image.height, warnings: limited.warnings))
    }

    /// Thumbnails are written to disk right after commit so the grid never waits on a decode (FR-007-07). Unstructured and
    /// unawaited on purpose: a failure only means the thumbnail is built on first view instead.
    private func warmThumbnails(_ itemId: UUID, source: Data) {
        let database = self.database
        Task.detached(priority: .utility) { await database.warmThumbnails(itemId: itemId, source: source) }
    }

    /// Step 7: the image budget (FR-007-08). The item is already committed, so a failure here is logged and never
    /// turns a successful ingest into a failed one; the next image ingest or sweep tries again. The returned
    /// `STO-LIM-001`, if any, travels in the result's warnings for the caller to show.
    private func enforceBudget(protecting itemId: UUID) async -> [FlotsamError] {
        let budget = settings.value(SettingKeys.storageImageBudget)
        switch await database.enforceImageBudget(budget, protecting: itemId) {
        case .success(let outcome): return outcome.notice.map { [$0] } ?? []
        case .failure(let error):
            FlotsamLog.log(error, category: .storage)
            return []
        }
    }

    // MARK: Step 3

    /// Writes every blob under the new item id. On any failure the ones already written are removed, so a failed
    /// ingest leaves no file behind (AC-007-04).
    private func writeBlobs(_ representations: [PasteboardRepresentation], itemId: UUID) -> FlotsamResult<[StoredRepresentation]> {
        var stored: [StoredRepresentation] = []
        for (ordinal, representation) in representations.enumerated() {
            switch database.blobs.write(representation.data, itemId: itemId, ordinal: ordinal) {
            case .success(let name):
                stored.append(StoredRepresentation(uti: representation.uti, byteSize: representation.data.count, blobName: name))
            case .failure(let error):
                removeBlobs(stored)
                return .failure(error)
            }
        }
        return .success(stored)
    }

    private func removeBlobs(_ stored: [StoredRepresentation]) {
        for representation in stored { _ = database.blobs.remove(blobName: representation.blobName) }
    }

    // MARK: Step 4

    private static func insert(
        _ db: Database, itemId: UUID, candidate: IngestCandidate, prepared: PreparedItem, stored: [StoredRepresentation]
    ) throws {
        let id = itemId.uuidString
        let at = candidate.occurredAt.epochMillis
        // Sum of stored representations only: plain text lives in `item.plainText`, thumbnails are not counted (FRD-007 data model).
        let byteSize = stored.reduce(0) { $0 + $1.byteSize }
        try db.execute(
            sql: """
                INSERT INTO item (id, kind, createdAt, lastCopiedAt, contentKey, plainText, sourceBundleId, sourceName,
                                  byteSize, pixelWidth, pixelHeight, originalPath, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                id, candidate.kind.rawValue, at, at, candidate.contentKey, candidate.plainText,
                candidate.source?.bundleId, candidate.source?.name, byteSize,
                prepared.pixelWidth, prepared.pixelHeight, candidate.originalPath, at,
            ])
        for representation in stored {
            try db.execute(
                sql: "INSERT INTO representation (itemId, uti, byteSize, blobName) VALUES (?, ?, ?, ?)",
                arguments: [id, representation.uti, representation.byteSize, representation.blobName])
        }
        for (ordinal, member) in prepared.members.enumerated() {
            try db.execute(
                sql: "INSERT INTO bundleMember (itemId, ordinal, path, bookmark, isDirectory) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, ordinal, member.path, member.bookmark, member.isDirectory])
        }
        try SearchIndex.refresh(db, itemId: id)
    }

    // MARK: Values

    private enum Inserted: Sendable {
        case created
        case raced(String)
    }

    /// The candidate after limits and the image pipeline: what actually gets stored.
    private struct PreparedItem: Sendable {
        let representations: [PasteboardRepresentation]
        let members: [IngestMember]
        let pixelWidth: Int?
        let pixelHeight: Int?
        let warnings: [FlotsamError]
    }

    private struct StoredRepresentation: Sendable {
        let uti: String
        let byteSize: Int
        let blobName: String
    }
}
