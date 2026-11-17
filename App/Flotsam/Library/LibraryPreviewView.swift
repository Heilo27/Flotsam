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
                    if let text = preview.text(showingAll: showingAll) {
                        Text(verbatim: text).font(.body.monospaced()).textSelection(.enabled)
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
                    ForEach(preview.fields, id: \.label) { field in
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: field.label).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
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
}
