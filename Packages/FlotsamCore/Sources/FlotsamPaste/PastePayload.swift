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
        // A secure clip is never written from stored content: its text exists only after `SecureClipAccess.reveal`
        // (the user's authentication). Until a caller reveals it, refuse rather than write an empty string.
        if content.isSecure {
            return .failure(FlotsamError(.libOs002, "A secure item needs authentication to copy", context: [.itemId: .id(itemId)]))
        }
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
