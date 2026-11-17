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

/// Everything needed to put an item back on the pasteboard (FRD-003 FR-003-15): the plain text, every stored
/// representation with its bytes, and the file members.
public struct ItemContent: Sendable, Equatable {
    public let kind: ItemKind
    public let plainText: String?
    public let representations: [PasteboardRepresentation]
    public let members: [ItemMember]

    public init(kind: ItemKind, plainText: String?, representations: [PasteboardRepresentation], members: [ItemMember]) {
        self.kind = kind
        self.plainText = plainText
        self.representations = representations
        self.members = members
    }
}

extension FlotsamDatabase {
    /// Loads the paste payload of one item. A missing row or an unreadable blob is `LIB-IO-001` (the caller deletes
    /// the item, FR-003-20); a database failure is `STO-DB-004`.
    public func content(of itemId: UUID) async -> FlotsamResult<ItemContent> {
        struct Stored { let kind: String; let plainText: String?; let blobs: [(uti: String, blobName: String)]; let members: [ItemMember] }
        let stored: Stored?
        do {
            stored = try await pool.read { db in
                let id = itemId.uuidString
                guard let item = try Row.fetchOne(db, sql: "SELECT kind, plainText FROM item WHERE id = ?", arguments: [id]) else {
                    return nil
                }
                let blobs = try Row.fetchAll(
                    db, sql: "SELECT uti, blobName FROM representation WHERE itemId = ? ORDER BY id", arguments: [id])
                    .map { (uti: $0["uti"] as String, blobName: $0["blobName"] as String) }
                let members = try Row.fetchAll(
                    db, sql: "SELECT path, bookmark, isDirectory FROM bundleMember WHERE itemId = ? ORDER BY ordinal", arguments: [id])
                    .map { ItemMember(path: $0["path"], bookmark: $0["bookmark"], isDirectory: $0["isDirectory"]) }
                return Stored(kind: item["kind"], plainText: item["plainText"], blobs: blobs, members: members)
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
            representations: representations, members: stored.members))
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
