import Foundation

/// Where a file item's member is now, and whether any of an item's files are left. The one home for "does this
/// referenced file still exist" (FRD-003 FR-003-07, FR-003-15). Callers, all through `ItemMember` (Storage): the
/// Library query (the Missing badge, via `LibraryQueries`), the Shelf's Missing badge (`ShelfModel`), paste
/// (`PastePayload`) and the Shelf drag-out (`ShelfDragPlanner`), the last two through `ItemContent.existingMemberURLs`.
/// The "none of the members exist" aggregate is `Collection<ItemMember>.anyExists`.
public enum FileMemberLocator {
    /// The member's current location: where its bookmark says (it follows a move or rename), else the stored path.
    /// Nil when nothing exists there any more.
    public static func currentURL(path: String, bookmark: Data?, isDirectory: Bool, files: any FileSystemPort) -> URL? {
        var candidates: [URL] = []
        if let bookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                bookmarkDataIsStale: &stale)
            {
                candidates.append(resolved)
            }
        }
        candidates.append(URL(fileURLWithPath: path, isDirectory: isDirectory))
        return candidates.first { files.fileExists(at: $0) }
    }
}
