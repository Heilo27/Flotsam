import FlotsamBase
import Foundation

/// The rules for turning stored content back into pasteboard representations. FR-003-15 (paste) and FR-006-10 (Shelf
/// drag) both follow them, so they live here once; each caller adds only what differs (paste modes and the own-write
/// marker, the drag's one-item-per-member split).
extension ItemContent {
    /// Text-bearing kinds: the plain text, then every stored representation. Every other kind: the stored
    /// representations as they are (an image's bytes).
    public var storedRepresentations: [PasteboardRepresentation] {
        guard kind.isTextBearing else { return representations }
        return [plainTextRepresentation] + representations
    }

    /// The plain text as a pasteboard representation (empty when the item has none).
    public var plainTextRepresentation: PasteboardRepresentation {
        PasteboardRepresentation(uti: PasteboardUTI.plainText, data: Data((plainText ?? "").utf8))
    }

    /// One file-URL representation for a location.
    public static func fileURLRepresentation(for url: URL) -> PasteboardRepresentation {
        PasteboardRepresentation(uti: PasteboardUTI.fileURL, data: Data(url.absoluteString.utf8))
    }

    /// Where each member is now, in member order; members whose file is gone are left out.
    public func existingMemberURLs(files: any FileSystemPort) -> [URL] {
        members.compactMap { $0.currentURL(files: files) }
    }
}

extension ItemMember {
    /// Where this member is now (`FileMemberLocator`); nil when nothing exists there any more.
    public func currentURL(files: any FileSystemPort) -> URL? {
        FileMemberLocator.currentURL(path: path, bookmark: bookmark, isDirectory: isDirectory, files: files)
    }
}

extension Collection where Element == ItemMember {
    /// Whether at least one member still exists. The Missing state is its negation for a file, folder or bundle
    /// item (FRD-003 FR-003-07): a bundle with one member left is not Missing, and an empty one is. The Library's
    /// rows and the Shelf's cards both ask this, so the two cannot disagree.
    public func anyExists(files: any FileSystemPort) -> Bool {
        contains { $0.currentURL(files: files) != nil }
    }
}
