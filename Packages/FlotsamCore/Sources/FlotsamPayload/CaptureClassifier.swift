import FlotsamBase
import Foundation

/// Turns the representations read from the pasteboard into one classified candidate (FR-001-08 to FR-001-12,
/// FR-001-15). Pure apart from reading file metadata, so it runs on the ingest side of the hand-off and never on the
/// main thread (FR-001-17).
public enum CaptureClassifier {
    /// `representations` may hold several `public.file-url` entries (one per pasteboard item, in order); every other
    /// type appears at most once.
    public static func classify(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Classification> {
        let fileURLs = representations.filter { $0.uti == PasteboardTypes.fileURL }
        if !fileURLs.isEmpty { return classifyFiles(fileURLs) }

        let plainBytes = representations.first { $0.uti == PasteboardTypes.plainText }?.data
        let rich = representations.filter { ($0.uti == PasteboardTypes.rtf || $0.uti == PasteboardTypes.html) && !$0.data.isEmpty }
        if let text = textClassification(plainBytes: plainBytes, rich: rich, all: representations) { return text }

        // Precedence 3: an honoured image and no non-whitespace plain text.
        if let image = PasteboardTypes.imagePriority.lazy.compactMap({ type in
            representations.first { $0.uti == type && !$0.data.isEmpty }
        }).first {
            return .success(Classification(
                kind: .image, contentKey: ContentKey.image(image.data), plainText: nil,
                representations: [image], members: []))
        }
        return .failure(FlotsamError(.capVal001, "pasteboard holds nothing storable"))
    }

    // MARK: Text

    private static func textClassification(
        plainBytes: Data?, rich: [PasteboardRepresentation], all: [PasteboardRepresentation]
    ) -> FlotsamResult<Classification>? {
        var bytes: Data
        var text: String
        if let plainBytes, !isBlank(String(decoding: plainBytes, as: UTF8.self)) {
            bytes = plainBytes
            text = String(decoding: plainBytes, as: UTF8.self)
        } else if let derived = derivedPlainText(from: rich) {
            // FR-001-10: no usable plain text, so it comes from the markup; blank markup is CAP-VAL-001.
            bytes = Data(derived.utf8)
            text = derived
        } else {
            // Whitespace-only plain text never wins over an image (FR-001-08 rule 3); with nothing else it is empty.
            let hasImage = all.contains { PasteboardTypes.imagePriority.contains($0.uti) && !$0.data.isEmpty }
            return hasImage ? nil : .failure(FlotsamError(.capVal001, "pasteboard text is empty"))
        }
        let urlText = all.first { $0.uti == PasteboardTypes.url }.map { String(decoding: $0.data, as: UTF8.self) }
        let kind = TypedTextDetector.detect(text, urlText: urlText?.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? (rich.isEmpty ? .text : .richText)
        return .success(Classification(
            kind: kind, contentKey: ContentKey.text(bytes), plainText: text,
            representations: rich, members: []))
    }

    private static func derivedPlainText(from rich: [PasteboardRepresentation]) -> String? {
        for representation in rich {
            let text = representation.uti == PasteboardTypes.rtf
                ? MarkupText.plainText(fromRTF: representation.data)
                : MarkupText.plainText(fromHTML: representation.data)
            if !isBlank(text) { return text }
        }
        return nil
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Files

    private static func classifyFiles(_ entries: [PasteboardRepresentation]) -> FlotsamResult<Classification> {
        var members: [ClassifiedMember] = []
        var seenAny = false
        for entry in entries {
            guard let url = PasteboardTypes.fileURL(from: entry.data) else { continue }
            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            // Filtered to what exists at capture time (FR-001-12).
            guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else { continue }
            seenAny = true
            // Bookmarks only for the first `BundleLimits.maxMembers` (FR-001-12): ingest keeps no more than that, so
            // later members stay in the list by path alone and ingest still sees, and reports, the true count.
            let bookmark = members.count < BundleLimits.maxMembers ? try? standardized.bookmarkData() : nil
            members.append(ClassifiedMember(
                path: standardized.path, bookmark: bookmark, isDirectory: isDirectory.boolValue))
        }
        guard seenAny else { return .failure(FlotsamError(.capDat001, "copied files no longer exist")) }

        let paths = members.map(\.path)
        let keyed: ItemClassification
        if members.count > 1 {
            keyed = classifyFileSet(paths: paths)
        } else if let only = members.first {
            keyed = classifyMember(path: only.path, isDirectory: only.isDirectory)
        } else {
            keyed = ItemClassification(kind: .file, contentKey: ContentKey.files(paths: paths))
        }
        return .success(Classification(
            kind: keyed.kind, contentKey: keyed.contentKey, plainText: nil,
            representations: [], members: members))
    }

    /// FR-001-12: with auto-bundling off, a copy of several files is one item per file, in pasteboard order. Each
    /// member is classified exactly as a copy of that one file would be, so it dedupes against one. Anything that is
    /// not a multi-member file set comes back as it is.
    public static func splitIntoMembers(_ classification: Classification) -> [Classification] {
        guard classification.kind == .bundle, classification.members.count > 1 else { return [classification] }
        return classification.members.map { member in
            let keyed = classifyMember(path: member.path, isDirectory: member.isDirectory)
            return Classification(
                kind: keyed.kind, contentKey: keyed.contentKey, plainText: nil, representations: [], members: [member])
        }
    }
}
