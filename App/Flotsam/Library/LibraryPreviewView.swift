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
        Group {
            if let preview {
                // The content scrolls in the area that is left; the metadata is a compact footer block under it (FR-003-14), so
                // a short clip no longer leaves the pane empty below its fields.
                VStack(spacing: 0) {
                    ScrollView {
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
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(preview.itemId)
                    }
                    .frame(maxHeight: .infinity)
                    Divider()
                    ScrollView {
                        metadata(preview.fields).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: Self.metadataMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(verbatim: LibraryText.string(LibraryText.previewUnavailable))
                    .foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onChange(of: preview?.itemId) { _, _ in showingAll = false }
    }

    /// The footer block's tallest size: past this it scrolls, so a clip with many fields never squeezes the content away.
    private static let metadataMaxHeight: CGFloat = 150

    /// The width of the fade at the right edge of a sideways-scrolling block (FR-003-14).
    private static let trailingFade: CGFloat = 24

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
            SidewaysText(text: text, fade: Self.trailingFade)
        } else {
            Text(verbatim: text).font(.callout.monospaced()).textSelection(.enabled)
        }
    }

    private static func attributedText(rtf: Data) -> AttributedString? {
        guard let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil), attributed.length > 0 else { return nil }
        return try? AttributedString(attributed, including: \.swiftUI)
    }
}

/// Indented text (code): monospaced, never soft-wrapped, scrolls sideways. When the lines are wider than the pane the right edge
/// fades over `fade` points, so the cut reads as a deliberate scroll cue; a trailing pad of the same width lets the longest line
/// scroll clear of the fade.
private struct SidewaysText: View {
    let text: String
    let fade: CGFloat
    @State private var viewportWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        let overflows = contentWidth > viewportWidth
        ScrollView(.horizontal) {
            Text(verbatim: text).font(.callout.monospaced()).fixedSize(horizontal: true, vertical: true).textSelection(.enabled)
                .padding(.trailing, overflows ? fade : 0)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { contentWidth = $0 - (overflows ? fade : 0) }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { viewportWidth = $0 }
        .mask(
            HStack(spacing: 0) {
                Rectangle()
                if overflows { LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: fade) }
            })
    }
}
