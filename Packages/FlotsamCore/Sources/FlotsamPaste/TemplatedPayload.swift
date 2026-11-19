import FlotsamBase
import FlotsamStorage
import Foundation

/// What a trigger or item hotkey puts on the pasteboard for one item: the paste payload (FR-003-15 steps 1 and 2) with
/// template variables expanded (FR-005-14 step 1, FR-005-17, FR-005-18). Library paste does not come through here; it
/// writes the stored text literally.
public enum TemplatedPayload {
    /// Failure codes: `TRG-VAL-006` (a secure item, FR-005-23: never a trigger or hotkey payload, and it is refused before anything
    /// is revealed, so no prompt appears and a password is never run through variable expansion), `LIB-DAT-001`
    /// (every file of a file item is gone), `TRG-OS-002` (rich text could not be decoded or
    /// encoded). Nothing has been written to the pasteboard when this fails, so the caller's failure path is FR-005-15's.
    public static func representations(
        for content: ItemContent, itemId: UUID, context: TemplateContext, codec: any RichTextCodec,
        files: any FileSystemPort
    ) -> FlotsamResult<[PasteboardRepresentation]> {
        guard !content.isSecure else {
            return .failure(FlotsamError(.trgVal006, "A secure item cannot be pasted by a trigger", context: [.itemId: .id(itemId)]))
        }
        let stored: [PasteboardRepresentation]
        switch PastePayload.representations(for: content, mode: .paste, itemId: itemId, files: files) {
        case .success(let built): stored = built
        case .failure(let error): return .failure(error)
        }
        guard content.kind.isTextBearing, let plainText = content.plainText,
            TemplateVariables.hasSubstitutions(in: plainText)
        else { return .success(stored) }

        // The expanded text replaces the stored text, so any representation derived from it (a `public.url`, the stored
        // RTF) would now disagree with it. Only the plain text and, for rich text, the re-encoded rich forms are kept.
        let plain = PasteboardRepresentation(
            uti: PasteboardUTI.plainText,
            data: Data(TemplateVariables.expand(plainText, context: context).utf8))
        guard content.kind == .richText,
            stored.contains(where: { RichTextTypes.all.contains($0.uti) })
        else { return .success([plain]) }

        guard let attributed = codec.decode(stored.filter { RichTextTypes.all.contains($0.uti) }) else {
            return .failure(FlotsamError(.trgOs002, "Rich text item could not be decoded", context: [.itemId: .id(itemId)]))
        }
        switch codec.encode(TemplateVariables.expand(attributed, context: context)) {
        case .success(let rich): return .success([plain] + rich)
        case .failure(let error): return .failure(error)
        }
    }
}
