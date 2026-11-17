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

    public init(database: FlotsamDatabase) {
        self.database = database
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
        switch prepare(candidate) {
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
            return .success(IngestResult(outcome: .created(itemId), warnings: prepared.warnings))
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

    /// Limits (FR-007-06) now; the disk guard and image pipeline hook in here (FR-007-14, -07).
    private func prepare(_ candidate: IngestCandidate) -> FlotsamResult<PreparedItem> {
        switch IngestLimits.apply(to: candidate) {
        case .failure(let error): return .failure(error)
        case .success(let limited):
            return .success(PreparedItem(
                representations: limited.representations, members: limited.members,
                pixelWidth: nil, pixelHeight: nil, warnings: limited.warnings))
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
        let byteSize = (candidate.plainText?.utf8.count ?? 0) + stored.reduce(0) { $0 + $1.byteSize }
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
