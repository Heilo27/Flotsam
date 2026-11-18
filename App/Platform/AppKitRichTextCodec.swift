import AppKit
import FlotsamBase
import Foundation

/// RTF and HTML to and from `AttributedString`, through AppKit's document importers and exporters (FR-005-17). The
/// package cannot import AppKit (ADR-0001), so it reaches this through `RichTextCodec`.
///
/// The HTML importer is WebKit-backed and only safe on the main thread, so HTML is decoded there and skipped (decode
/// returns nil when RTF is absent) anywhere else. RTF has no such limit.
struct AppKitRichTextCodec: RichTextCodec {
    func decode(_ representations: [PasteboardRepresentation]) -> AttributedString? {
        // RTF first, then HTML (RichTextPorts contract).
        for (type, documentType) in [(RichTextTypes.rtf, NSAttributedString.DocumentType.rtf), (RichTextTypes.html, .html)] {
            if documentType == .html, !Thread.isMainThread { continue }
            guard let representation = representations.first(where: { $0.uti == type }),
                let decoded = try? NSAttributedString(
                    data: representation.data, options: [.documentType: documentType], documentAttributes: nil),
                let attributed = try? AttributedString(decoded, including: \.appKit)
            else { continue }
            return attributed
        }
        return nil
    }

    func encode(_ text: AttributedString) -> FlotsamResult<[PasteboardRepresentation]> {
        guard let native = try? NSAttributedString(text, including: \.appKit) else {
            return .failure(FlotsamError(.trgOs002, "Expanded rich text could not be converted for the pasteboard"))
        }
        let range = NSRange(location: 0, length: native.length)
        var encoded: [PasteboardRepresentation] = []
        for (type, documentType) in [(RichTextTypes.rtf, NSAttributedString.DocumentType.rtf), (RichTextTypes.html, .html)] {
            if let data = try? native.data(from: range, documentAttributes: [.documentType: documentType]) {
                encoded.append(PasteboardRepresentation(uti: type, data: data))
            }
        }
        guard !encoded.isEmpty else {
            return .failure(FlotsamError(.trgOs002, "Expanded rich text could not be encoded as RTF or HTML"))
        }
        return .success(encoded)
    }
}
