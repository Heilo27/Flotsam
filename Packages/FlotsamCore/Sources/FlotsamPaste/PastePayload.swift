import FlotsamBase
import FlotsamStorage
import Foundation

/// Builds what goes on the pasteboard for one item (FR-003-15 steps 1 and 2). Pure apart from file-existence checks.
enum PastePayload {
    static let plainTextType = "public.utf8-plain-text"
    static let fileURLType = "public.file-url"

    /// Kinds whose content is text, so "plain text only" has meaning (FR-003-15).
    private static let textKinds: Set<ItemKind> = [.text, .richText, .link, .color, .phone, .email]

    /// The representations to write, or `LIB-DAT-001` when a file item has no member left on disk.
    static func representations(
        for content: ItemContent, mode: PasteMode, itemId: UUID, files: any FileSystemPort
    ) -> FlotsamResult<[PasteboardRepresentation]> {
        if content.kind.referencesFiles {
            let urls = content.members.compactMap {
                FileMemberLocator.currentURL(path: $0.path, bookmark: $0.bookmark, isDirectory: $0.isDirectory, files: files)
            }
            guard !urls.isEmpty else {
                return .failure(FlotsamError(.libDat001, "Every file of the item is gone", context: [.itemId: .id(itemId)]))
            }
            return .success(urls.map { PasteboardRepresentation(uti: fileURLType, data: Data($0.absoluteString.utf8)) })
        }
        guard textKinds.contains(content.kind) else { return .success(content.representations) }
        let text = PasteboardRepresentation(uti: plainTextType, data: Data((content.plainText ?? "").utf8))
        return .success(mode == .plainText ? [text] : [text] + content.representations)
    }
}
