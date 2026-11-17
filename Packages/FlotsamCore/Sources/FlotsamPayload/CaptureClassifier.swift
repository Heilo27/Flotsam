import FlotsamBase
import Foundation

/// A file or folder held by reference (FR-001-12). Payload may not import Storage (ADR-0001), so Capture maps this to
/// Storage's `IngestMember`.
public struct ClassifiedMember: Sendable, Equatable {
    public let path: String
    public let bookmark: Data?
    public let isDirectory: Bool
}

/// What a pasteboard classified as (FR-001-08): everything ingest needs except the source app and the time, which the
/// poll knows and the classifier does not.
public struct Classification: Sendable, Equatable {
    public let kind: ItemKind
    public let contentKey: String
    /// The text of text-like kinds; nil for image, file, folder and bundle.
    public let plainText: String?
    /// Everything that becomes a blob: rich text for text-like kinds, the chosen image for `image`.
    public let representations: [PasteboardRepresentation]
    public let members: [ClassifiedMember]
    /// Conditions to surface although the capture succeeded (`CAP-LIM-003`).
    public let warnings: [FlotsamError]
}

/// Turns the representations read from the pasteboard into one classified candidate (FR-001-08 to FR-001-12,
/// FR-001-15). Pure apart from reading file metadata, so it runs on the ingest side of the hand-off and never on the
/// main thread (FR-001-17).
public enum CaptureClassifier {
    /// FR-001-12: a bundle keeps its first 500 members.
    public static let maxBundleMembers = 500

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
                representations: [image], members: [], warnings: []))
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
            representations: rich, members: [], warnings: []))
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
        var trimmed = false
        for entry in entries {
            guard let url = fileURL(from: entry.data) else { continue }
            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            // Filtered to what exists at capture time (FR-001-12).
            guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else { continue }
            seenAny = true
            if members.count == maxBundleMembers { trimmed = true; continue }
            members.append(ClassifiedMember(
                path: standardized.path, bookmark: try? standardized.bookmarkData(), isDirectory: isDirectory.boolValue))
        }
        guard seenAny else { return .failure(FlotsamError(.capDat001, "copied files no longer exist")) }

        let paths = members.map(\.path)
        let warnings = trimmed
            ? [FlotsamError(.capLim003, "bundle trimmed to the member limit", context: [.count: .int(maxBundleMembers)])]
            : []
        let kind: ItemKind
        if members.count > 1 {
            kind = .bundle
        } else if let only = members.first {
            kind = memberKind(path: only.path, isDirectory: only.isDirectory)
        } else {
            kind = .file
        }
        return .success(Classification(
            kind: kind, contentKey: ContentKey.files(paths: paths), plainText: nil,
            representations: [], members: members, warnings: warnings))
    }

    /// `public.file-url` data is the URL string as UTF-8, `file:///...`.
    private static func fileURL(from data: Data) -> URL? {
        let string = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: string), url.isFileURL else { return nil }
        return url
    }
}
