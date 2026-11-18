import FlotsamBase
import FlotsamStorage
import Foundation

/// Builds what goes on the pasteboard for one item (FR-003-15 steps 1 and 2). Pure apart from file-existence checks.
/// The content-to-representation rules are shared with the Shelf drag and live on `ItemContent`.
enum PastePayload {
    /// The representations to write, or `LIB-DAT-001` when a file item has no member left on disk.
    static func representations(
        for content: ItemContent, mode: PasteMode, itemId: UUID, files: any FileSystemPort
    ) -> FlotsamResult<[PasteboardRepresentation]> {
        if content.kind.referencesFiles {
            let urls = content.existingMemberURLs(files: files)
            guard !urls.isEmpty else {
                return .failure(FlotsamError(.libDat001, "Every file of the item is gone", context: [.itemId: .id(itemId)]))
            }
            return .success(urls.map(ItemContent.fileURLRepresentation(for:)))
        }
        if mode == .plainText, content.kind.isTextBearing { return .success([content.plainTextRepresentation]) }
        return .success(content.storedRepresentations)
    }
}
