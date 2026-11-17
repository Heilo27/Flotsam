import FlotsamBase
import FlotsamStorage
import Foundation

/// Builds what goes on the pasteboard for one item (FR-003-15 steps 1 and 2). Pure apart from file-existence checks.
enum PastePayload {
    static let plainTextType = "public.utf8-plain-text"
    static let fileURLType = "public.file-url"

    /// Kinds whose content is text, so "plain text only" has meaning (FR-003-15).
    private static let textKinds: Set<ItemKind> = [.text, .richText, .link, .color, .phone, .email]
    private static let fileKinds: Set<ItemKind> = [.file, .folder, .bundle]

    /// The representations to write, or `LIB-DAT-001` when a file item has no member left on disk.
    static func representations(
        for content: ItemContent, mode: PasteMode, itemId: UUID, files: any FileSystemPort
    ) -> FlotsamResult<[PasteboardRepresentation]> {
        if fileKinds.contains(content.kind) {
            let urls = content.members.compactMap { existingURL(of: $0, files: files) }
            guard !urls.isEmpty else {
                return .failure(FlotsamError(.libDat001, "Every file of the item is gone", context: [.itemId: .id(itemId)]))
            }
            return .success(urls.map { PasteboardRepresentation(uti: fileURLType, data: Data($0.absoluteString.utf8)) })
        }
        guard textKinds.contains(content.kind) else { return .success(content.representations) }
        let text = PasteboardRepresentation(uti: plainTextType, data: Data((content.plainText ?? "").utf8))
        return .success(mode == .plainText ? [text] : [text] + content.representations)
    }

    /// The member's current location: where its bookmark says (it follows a move or rename), else the stored path.
    /// Nil when nothing exists there any more.
    private static func existingURL(of member: ItemMember, files: any FileSystemPort) -> URL? {
        var candidates: [URL] = []
        if let bookmark = member.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                candidates.append(resolved)
            }
        }
        candidates.append(URL(fileURLWithPath: member.path, isDirectory: member.isDirectory))
        return candidates.first { files.fileExists(at: $0) }
    }
}
