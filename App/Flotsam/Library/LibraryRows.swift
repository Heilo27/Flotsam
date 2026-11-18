import AppKit
import FlotsamBase
import FlotsamLibrary
import FlotsamPaste
import SwiftUI

/// The scrolling body: a list or a grid of the visible rows (FR-003-05, FR-003-07). Selection, paging and the
/// cursor are the model's; this only draws them and forwards pointer input.
struct LibraryItemsView: View {
    let model: LibraryViewModel
    private static let cellWidth: CGFloat = 130
    private static let cellSpacing: CGFloat = 10

    var body: some View {
        let rows = model.rowPresentations()
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    if model.viewMode == .list {
                        LazyVStack(spacing: 2) {
                            ForEach(rows) { row in
                                LibraryListRow(model: model, row: row).onAppear { pageIfLast(row, in: rows) }
                            }
                        }
                        .padding(8)
                    } else {
                        let columns = Self.columnCount(for: geometry.size.width)
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: Self.cellSpacing), count: columns),
                            spacing: Self.cellSpacing
                        ) {
                            ForEach(rows) { row in
                                LibraryGridCell(model: model, row: row).onAppear { pageIfLast(row, in: rows) }
                            }
                        }
                        .padding(10)
                        .onAppear { model.gridColumns = columns }
                        .onChange(of: columns) { _, new in model.gridColumns = new }
                    }
                }
                .onChange(of: model.cursorID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: model.scrollResetToken) { _, _ in
                    if let first = rows.first?.id { proxy.scrollTo(first, anchor: .top) }
                }
            }
        }
    }

    private func pageIfLast(_ row: LibraryRowPresentation, in rows: [LibraryRowPresentation]) {
        if row.id == rows.last?.id { model.loadMore() }
    }

    private static func columnCount(for width: CGFloat) -> Int {
        max(1, Int((width - 20 + cellSpacing) / (cellWidth + cellSpacing)))
    }
}

/// Click selects, ⌘-click toggles, ⇧-click extends, double-click pastes (FR-003-09); the context menu is FR-003-22.
private struct RowInteraction: ViewModifier {
    let model: LibraryViewModel
    let row: LibraryRowPresentation

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.select(id: row.id)
                model.perform(.paste(.paste))
            }
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                if flags.contains(.command) { model.toggle(id: row.id) }
                else if flags.contains(.shift) { model.extend(to: row.id) }
                else { model.select(id: row.id) }
            }
            .contextMenu {
                Button(LibraryText.string(LibraryText.menuPaste)) { act { model.perform(.paste(.paste)) } }
                Button(LibraryText.string(LibraryText.menuPastePlain)) { act { model.perform(.paste(.plainText)) } }
                Button(LibraryText.string(LibraryText.menuCopy)) { act { model.perform(.paste(.copyOnly)) } }
                Divider()
                Button(LibraryText.string(LibraryText.menuPreview)) { act { model.perform(.togglePreview) } }
                if row.kind.referencesFiles {
                    Button(LibraryText.string(LibraryText.menuReveal)) { act { model.perform(.revealInFinder) } }
                }
                Divider()
                organizeMenu
            }
            .id(row.id)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityAddTraits(model.selection.contains(row.id) ? .isSelected : [])
    }

    /// Pin, Tags, Note, Edit, Ungroup and Delete (FR-004-01, -03, -06, -07, -09, -11). Edit and Ungroup need exactly one
    /// item; the coordinator checks again, so a stale menu cannot act on the wrong selection.
    @ViewBuilder
    private var organizeMenu: some View {
        let single = !model.selection.contains(row.id) || model.selection.count == 1
        Button(LibraryText.string(model.pinActionUnpins(menuRowID: row.id, isPinned: row.isPinned) ? LibraryText.menuUnpin : LibraryText.menuPin)) { act { model.perform(.external(.pin)) } }
        Button(LibraryText.string(LibraryText.menuTags)) { act { model.perform(.external(.tags)) } }
        if single {
            Button(LibraryText.string(LibraryText.menuNote)) { act { model.perform(.external(.note)) } }
            if row.kind.isTextEditable {
                Button(LibraryText.string(LibraryText.menuEdit)) { act { model.perform(.external(.edit)) } }
            }
            if row.kind == .bundle {
                Button(LibraryText.string(LibraryText.menuUngroup)) { act { model.perform(.external(.ungroup)) } }
            }
        }
        Divider()
        Button(LibraryText.string(LibraryText.menuDelete), role: .destructive) { act { model.perform(.external(.delete)) } }
    }

    /// A context-menu command acts on the row it was opened on (FR-003-22).
    private func act(_ command: () -> Void) {
        if !model.selection.contains(row.id) { model.select(id: row.id) }
        command()
    }
}

private extension View {
    func rowInteraction(model: LibraryViewModel, row: LibraryRowPresentation) -> some View {
        modifier(RowInteraction(model: model, row: row))
    }
}

private func symbolName(for kind: ItemKind) -> String {
    switch kind {
    case .text: "text.alignleft"
    case .richText: "doc.richtext"
    case .link: "link"
    case .color: "paintpalette"
    case .phone: "phone"
    case .email: "envelope"
    case .image: "photo"
    case .file: "doc"
    case .folder: "folder"
    case .bundle: "shippingbox"
    case .screenshot: "camera.viewfinder"
    }
}

private func rowBackground(selected: Bool, cursor: Bool) -> some ShapeStyle {
    selected ? Color.accentColor.opacity(0.28) : (cursor ? Color.primary.opacity(0.08) : Color.clear)
}

private struct StatusBadges: View {
    let row: LibraryRowPresentation

    var body: some View {
        HStack(spacing: 4) {
            if row.isPinned { Image(systemName: "pin.fill") }
            if row.hasTrigger { Image(systemName: "text.cursor") }
            if row.hasShortcut { Image(systemName: "command") }
            if let missing = row.missingBadge {
                Text(verbatim: missing).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

private struct TagChips: View {
    let row: LibraryRowPresentation

    var body: some View {
        ForEach(row.tagChips, id: \.self) { tag in
            Text(verbatim: tag).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
        if let overflow = row.tagOverflow { Text(verbatim: overflow).font(.caption2).foregroundStyle(.secondary) }
    }
}

struct LibraryListRow: View {
    let model: LibraryViewModel
    let row: LibraryRowPresentation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName(for: row.kind)).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.primaryText).lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: row.secondaryText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    TagChips(row: row)
                }
            }
            Spacer(minLength: 4)
            StatusBadges(row: row)
            if let badge = row.shortcutBadge { Text(verbatim: badge).font(.caption.monospaced()).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            rowBackground(selected: model.selection.contains(row.id), cursor: model.cursorID == row.id),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .rowInteraction(model: model, row: row)
    }
}

struct LibraryGridCell: View {
    let model: LibraryViewModel
    let row: LibraryRowPresentation
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: symbolName(for: row.kind)).font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(height: 70)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(verbatim: row.primaryText).font(.caption).lineLimit(2)
            HStack(spacing: 4) {
                StatusBadges(row: row)
                if let badge = row.shortcutBadge { Text(verbatim: badge).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            }
        }
        .padding(6)
        .background(
            rowBackground(selected: model.selection.contains(row.id), cursor: model.cursorID == row.id),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .task(id: row.id) {
            guard row.kind == .image || row.kind == .screenshot else { return }
            if let data = await model.thumbnail(for: row.id, size: .grid) { thumbnail = NSImage(data: data) }
        }
        .rowInteraction(model: model, row: row)
    }
}
