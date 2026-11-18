import FlotsamBase
import Foundation
import GRDB

/// One file or folder an item refers to (FRD-007 `bundleMember`).
public struct ItemMember: Sendable, Equatable {
    public let path: String
    public let bookmark: Data?
    public let isDirectory: Bool

    public init(path: String, bookmark: Data?, isDirectory: Bool) {
        self.path = path
        self.bookmark = bookmark
        self.isDirectory = isDirectory
    }
}

/// A tag on an item, as the preview lists it (FR-003-14): name and colour.
public struct ItemTag: Sendable, Equatable {
    public let name: String
    public let color: TagColor

    public init(name: String, color: TagColor) {
        self.name = name
        self.color = color
    }
}

/// Everything needed to put an item back on the pasteboard (FRD-003 FR-003-15): the plain text, every stored
/// representation with its bytes, and the file members; with the facts the preview's metadata block adds (FR-003-14):
/// when it was first copied, how often, its note and its tags.
public struct ItemContent: Sendable, Equatable {
    public let kind: ItemKind
    public let plainText: String?
    public let representations: [PasteboardRepresentation]
    public let members: [ItemMember]
    /// When the item was first copied; nil when the loader did not read it.
    public let firstCopiedAt: Date?
    public let copyCount: Int
    public let note: String?
    /// Alphabetical by name, like `ItemRow.tagNames`.
    public let tags: [ItemTag]

    public init(
        kind: ItemKind, plainText: String?, representations: [PasteboardRepresentation], members: [ItemMember],
        firstCopiedAt: Date? = nil, copyCount: Int = 1, note: String? = nil, tags: [ItemTag] = []
    ) {
        self.kind = kind
        self.plainText = plainText
        self.representations = representations
        self.members = members
        self.firstCopiedAt = firstCopiedAt
        self.copyCount = copyCount
        self.note = note
        self.tags = tags
    }
}

extension FlotsamDatabase {
    /// Loads the paste payload of one item. A missing row or an unreadable blob is `LIB-IO-001` (the caller deletes
    /// the item, FR-003-20); a database failure is `STO-DB-004`.
    public func content(of itemId: UUID) async -> FlotsamResult<ItemContent> {
        struct Stored {
            let kind: String; let plainText: String?; let createdAt: Int64; let copyCount: Int; let note: String?
            let tags: [ItemTag]; let blobs: [(uti: String, blobName: String)]; let members: [ItemMember] }
        let stored: Stored?
        do {
            stored = try await pool.read { db in
                let id = itemId.uuidString
                guard let item = try Row.fetchOne(db, sql: "SELECT kind, plainText, createdAt, copyCount, note FROM item WHERE id = ?", arguments: [id]) else {
                    return nil
                }
                let blobs = try Row.fetchAll(
                    db, sql: "SELECT uti, blobName FROM representation WHERE itemId = ? ORDER BY id", arguments: [id])
                    .map { (uti: $0["uti"] as String, blobName: $0["blobName"] as String) }
                let members = try Row.fetchAll(
                    db, sql: "SELECT path, bookmark, isDirectory FROM bundleMember WHERE itemId = ? ORDER BY ordinal", arguments: [id])
                    .map { ItemMember(path: $0["path"], bookmark: $0["bookmark"], isDirectory: $0["isDirectory"]) }
                let tags = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT tag.name, tag.color FROM itemTag JOIN tag ON tag.id = itemTag.tagId
                        WHERE itemTag.itemId = ? ORDER BY tag.name COLLATE NOCASE
                        """,
                    arguments: [id])
                    .map { ItemTag(name: $0["name"], color: TagColor(stored: $0["color"])) }
                return Stored(
                    kind: item["kind"], plainText: item["plainText"], createdAt: item["createdAt"],
                    copyCount: item["copyCount"], note: item["note"], tags: tags, blobs: blobs, members: members)
            }
        } catch {
            return .failure(Self.readFailure(error))
        }
        guard let stored else {
            return .failure(FlotsamError(.libIo001, "Item row is gone", context: [.itemId: .id(itemId)]))
        }
        var representations: [PasteboardRepresentation] = []
        for blob in stored.blobs {
            switch blobs.read(blobName: blob.blobName) {
            case .success(let data): representations.append(PasteboardRepresentation(uti: blob.uti, data: data))
            case .failure:
                return .failure(FlotsamError(.libIo001, "Stored representation is missing", context: [.itemId: .id(itemId)]))
            }
        }
        return .success(ItemContent(
            kind: ItemKind(rawValue: stored.kind) ?? .text, plainText: stored.plainText,
            representations: representations, members: stored.members,
            firstCopiedAt: Date(epochMillis: stored.createdAt), copyCount: stored.copyCount, note: stored.note,
            tags: stored.tags))
    }

    /// FR-003-15 step 4: one more paste, and "last used" is now. Never edits the stored content (a paste does not
    /// modify an item).
    public func recordPaste(of itemId: UUID) async -> FlotsamResult<Void> {
        do {
            let now = clock.now().epochMillis
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE item SET pasteCount = pasteCount + 1, lastUsedAt = ? WHERE id = ?",
                    arguments: [now, itemId.uuidString])
            }
            return .success(())
        } catch {
            return .failure(Self.writeFailure(error))
        }
    }
}
