import AppKit
import FlotsamBase
import FlotsamLibrary
import SwiftUI

/// The preview pane (FR-003-14): read-only content for the single selected row, then its fields.
struct LibraryPreviewView: View {
    let model: LibraryViewModel
    @State private var showingAll = false

    var body: some View {
        ScrollView {
            if let preview = model.preview {
                VStack(alignment: .leading, spacing: 10) {
                    if let data = preview.imageData, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    }
                    if let color = preview.color {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(color))
                            .frame(height: 96)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    } else if let text = preview.text(showingAll: showingAll) {
                        textBody(text, rtf: showingAll || !preview.isTruncated ? preview.richTextRTF : nil)
                        if preview.isTruncated && !showingAll {
                            Button(LibraryText.string(LibraryText.previewShowMore)) { showingAll = true }
                        }
                    }
                    ForEach(preview.memberPaths, id: \.self) { path in
                        Text(verbatim: path).font(.caption).lineLimit(2).textSelection(.enabled)
                    }
                    if preview.hiddenMemberCount > 0 {
                        Text(verbatim: LibraryText.previewMore(preview.hiddenMemberCount))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    ForEach(preview.fields) { field in
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: field.label).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if let tagColor = field.tagColor {
                                Circle().fill(tagColor.swatch).frame(width: 8, height: 8)
                            }
                            Text(verbatim: field.value).font(.caption).multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(12)
                .id(preview.itemId)
            } else {
                Text(verbatim: LibraryText.string(LibraryText.previewUnavailable))
                    .foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity)
            }
        }
        .onChange(of: model.preview?.itemId) { _, _ in showingAll = false }
    }

    /// The item's text. A rich text item keeps its formatting (bold, italics, colours, sizes) when its RTF reads; any
    /// other text, and a rich text item whose RTF does not read, is plain monospaced text.
    @ViewBuilder private func textBody(_ text: String, rtf: Data?) -> some View {
        if let rtf, let styled = Self.attributedText(rtf: rtf) {
            Text(styled).textSelection(.enabled)
        } else {
            Text(verbatim: text).font(.body.monospaced()).textSelection(.enabled)
        }
    }

    private static func attributedText(rtf: Data) -> AttributedString? {
        guard let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil), attributed.length > 0 else { return nil }
        return try? AttributedString(attributed, including: \.swiftUI)
    }
}
