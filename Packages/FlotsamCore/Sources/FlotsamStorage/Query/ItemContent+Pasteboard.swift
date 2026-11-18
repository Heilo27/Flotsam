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
        members.compactMap { $0.existingURL(files: files) }
    }
}

extension ItemMember {
    /// The member's current location: where its bookmark says (it follows a move or rename), else the stored path.
    /// Nil when nothing exists there any more.
    public func existingURL(files: any FileSystemPort) -> URL? {
        var candidates: [URL] = []
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                candidates.append(resolved)
            }
        }
        candidates.append(URL(fileURLWithPath: path, isDirectory: isDirectory))
        return candidates.first { files.fileExists(at: $0) }
    }
}
