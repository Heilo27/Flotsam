import AppKit
import FlotsamBase
import FlotsamLibrary
import SwiftUI

/// The preview pane (FR-003-14): read-only content for the single selected row, then its fields. The hover preview draws
/// the same view for the hovered row (FR-003-27), so there is one renderer.
struct LibraryPreviewView: View {
    let preview: LibraryPreview?
    @State private var showingAll = false

    var body: some View {
        ScrollView {
            if let preview {
                VStack(alignment: .leading, spacing: 10) {
                    if let data = preview.imageData, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    }
                    if let color = preview.color {
                        RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                            .fill(Color(color))
                            .frame(height: 96)
                            .overlay(RoundedRectangle(cornerRadius: DesignToken.Radius.card).stroke(.quaternary))
                    } else if let text = preview.text(showingAll: showingAll) {
                        textBody(text, rtf: showingAll || !preview.isTruncated ? preview.richTextRTF : nil, indented: preview.textIsIndented)
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
                    metadata(preview.fields)
                }
                .padding(12)
                .id(preview.itemId)
            } else {
                Text(verbatim: LibraryText.string(LibraryText.previewUnavailable))
                    .foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity)
            }
        }
        .onChange(of: preview?.itemId) { _, _ in showingAll = false }
    }

    /// The metadata as one compact block (FR-003-14): Kind, Source and Copied together on one or two lines, then any other
    /// field as a short label and value line, then the tags as chips. The content above gets everything the block saves.
    @ViewBuilder private func metadata(_ fields: [LibraryPreview.Field]) -> some View {
        let summary = fields.filter { $0.placement == .summary }
        let identity = summary.filter { $0.label != copiedLabel }.map(\.value).joined(separator: " · ")
        VStack(alignment: .leading, spacing: 3) {
            if !identity.isEmpty { Text(verbatim: identity).font(.caption) }
            ForEach(summary.filter { $0.label == copiedLabel }) { field in
                Text(verbatim: [field.label, field.value].joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(fields.filter { $0.placement == .detail }) { field in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: field.label).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: field.value).font(.caption)
                }
            }
            let tags = fields.filter { $0.placement == .tag }
            if !tags.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(tags) { tag in
                        HStack(spacing: 4) {
                            if let color = tag.tagColor { Circle().fill(color.swatch).frame(width: 8, height: 8) }
                            Text(verbatim: tag.value).font(.caption2).lineLimit(1)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignToken.Radius.chip))
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var copiedLabel: String { LibraryText.string("ui.library.previewCopied") }

    /// The item's text. A rich text item keeps its formatting (bold, italics, colours, sizes) when its RTF reads; any
    /// other text, and a rich text item whose RTF does not read, is plain monospaced text.
    /// Indented text (code) is not soft-wrapped: its lines keep their indentation and the block scrolls sideways (FR-003-14).
    @ViewBuilder private func textBody(_ text: String, rtf: Data?, indented: Bool) -> some View {
        if let rtf, let styled = Self.attributedText(rtf: rtf) {
            Text(styled).textSelection(.enabled)
        } else if indented {
            ScrollView(.horizontal) {
                Text(verbatim: text).font(.callout.monospaced()).fixedSize(horizontal: true, vertical: true).textSelection(.enabled)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        } else {
            Text(verbatim: text).font(.callout.monospaced()).textSelection(.enabled)
        }
    }

    private static func attributedText(rtf: Data) -> AttributedString? {
        guard let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil), attributed.length > 0 else { return nil }
        return try? AttributedString(attributed, including: \.swiftUI)
    }
}
