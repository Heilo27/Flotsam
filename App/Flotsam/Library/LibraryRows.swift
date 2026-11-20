import AppKit
import FlotsamBase
import FlotsamLibrary
import FlotsamPaste
import SwiftUI

/// The scrolling body: a list or a grid of the visible rows (FR-003-05, FR-003-07). Selection, paging and the
/// cursor are the model's; this only draws them and forwards pointer input.
struct LibraryItemsView: View {
    let model: LibraryViewModel
    let dragOut: ShelfDragOut
    private static let cellWidth: CGFloat = 130
    private static let cellSpacing: CGFloat = 10
    private static let hoverCardSize = CGSize(width: 280, height: 260)
    private static let space = "libraryItems"
    @State private var hoveredFrame: CGRect = .zero

    var body: some View {
        let rows = model.rowPresentations()
        GeometryReader { geometry in
            let isList = model.viewMode == .list
            // The list's viewport is a whole number of rows (FR-003-05): the footer edge falls between two rows, never through one.
            let fit = LibraryLayout.listFit(fitting: geometry.size.height)
            ScrollViewReader { proxy in
                ScrollView {
                    if isList {
                        LazyVStack(spacing: fit.rowSpacing) {
                            ForEach(rows) { row in
                                LibraryListRow(model: model, row: row, dragOut: dragOut).onAppear { pageIfLast(row, in: rows) }
                            }
                        }
                        .scrollTargetLayout()
                    } else {
                        let columns = Self.columnCount(for: geometry.size.width)
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: Self.cellSpacing), count: columns),
                            spacing: Self.cellSpacing
                        ) {
                            ForEach(rows) { row in
                                LibraryGridCell(model: model, row: row, dragOut: dragOut).onAppear { pageIfLast(row, in: rows) }
                            }
                        }
                        .onAppear { model.gridColumns = columns }
                        .onChange(of: columns) { _, new in model.gridColumns = new }
                    }
                }
                // Real scroll-content margins (FR-003-05). The list rests on row boundaries: scrolling snaps to a row, the top
                // margin clears the header and the bottom margin is one row gap, so the far end of the scroll ends on a row
                // boundary too and nothing needs a fade. The grid has no whole-row viewport: its last row scrolls fully out of
                // the shared bottom fade above the footer.
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, isList ? 8 : 10, for: .scrollContent)
                .contentMargins(.top, isList ? LibraryLayout.listTopMargin : 10, for: .scrollContent)
                .contentMargins(.bottom, isList ? fit.rowSpacing : LibraryScrollFade.height + 8, for: .scrollContent)
                .frame(height: isList ? min(fit.viewport, geometry.size.height) : nil)
                .fadingBottomEdge(isList ? 0 : LibraryScrollFade.height)
                .onChange(of: model.cursorID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: model.scrollResetToken) { _, _ in
                    if let first = rows.first?.id { proxy.scrollTo(first, anchor: .top) }
                }
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(HoveredRowFrameKey.self) { hoveredFrame = $0 }
        .overlay(alignment: .topTrailing) { hoverCard }
        // Ages the rows' relative times while the panel is shown (FR-003-24). The model owns the watch task and cancels
        // it on a hide; the key restarts it on the next open or row change.
        .task(id: model.relativeTimeWatchKey) { await model.runRelativeTimeWatch() }
    }

    /// The hover preview (FR-003-39): the preview view for the hovered row, placed below that row, or above it when there
    /// is no room, so it never covers the row or its action strip. It takes no pointer input, so it cannot steal the hover.
    @ViewBuilder private var hoverCard: some View {
        if let preview = model.hoverPreview {
            GeometryReader { geometry in
                let size = Self.hoverCardSize
                let below = hoveredFrame.maxY + 4
                let top = below + size.height <= geometry.size.height ? below : max(0, hoveredFrame.minY - 4 - size.height)
                LibraryPreviewView(preview: preview)
                    .frame(width: min(size.width, geometry.size.width - 16), height: size.height)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignToken.Radius.popover))
                    .overlay(RoundedRectangle(cornerRadius: DesignToken.Radius.popover).stroke(.quaternary))
                    .shadow(radius: 6)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                    .padding(.top, top)
            }
            .allowsHitTesting(false)
        }
    }

    private func pageIfLast(_ row: LibraryRowPresentation, in rows: [LibraryRowPresentation]) {
        if row.id == rows.last?.id { model.loadMore() }
    }

    private static func columnCount(for width: CGFloat) -> Int {
        max(1, Int((width - 20 + cellSpacing) / (cellWidth + cellSpacing)))
    }
}

/// Click selects, ⌘-click toggles, ⇧-click extends, double-click pastes (FR-003-09), a drag past the system threshold
/// drags the row out (FR-003-45); the context menu is FR-003-22. The mouse is `ShelfCardInteraction`, the one AppKit
/// view that tells a click from a drag (SwiftUI gestures cannot start a drag session).
private struct RowInteraction: ViewModifier {
    let model: LibraryViewModel
    let row: LibraryRowPresentation
    /// Where the hover strip overlays the row: trailing on a list row, top trailing on a grid cell.
    let stripAlignment: Alignment
    let dragOut: ShelfDragOut

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                ShelfCardInteraction(
                    onClick: { modifiers in
                        if modifiers.contains(.command) { model.toggle(id: row.id) }
                        else if modifiers.contains(.shift) { model.extend(to: row.id) }
                        else { model.select(id: row.id) }
                    },
                    onDoubleClick: {
                        model.select(id: row.id)
                        model.perform(.paste(.paste))
                    },
                    // A press is usually a click, and a click on a secure row must not ask the owner to authenticate
                    // (FR-003-45): nothing is read at mouse-down. The drag reads, and authenticates, when it starts.
                    prepareDrag: {},
                    beginDrag: { view, event in
                        // The hover strip and preview card belong to the pointer resting on a row, not to a drag (FR-003-45).
                        model.dragBegan()
                        dragOut.prepare(cardId: row.id)
                        await dragOut.begin(from: view, event: event)
                    })
            }
            .overlay(alignment: stripAlignment) { hoverStrip }
            .onHover { model.pointer(row.id, isInside: $0) }
            .background { hoverFrameReader }
            .contextMenu { contextMenu }
            .id(row.id)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityAddTraits(model.selection.contains(row.id) ? .isSelected : [])
    }

    /// The menu is `LibraryContextMenu` (FR-003-22); this only draws it. Note, Edit and Ungroup need exactly one item;
    /// the coordinator checks again, so a stale menu cannot act on the wrong selection.
    @ViewBuilder
    private var contextMenu: some View {
        let entries = LibraryContextMenu.entries(
            kind: row.kind,
            pinUnpins: model.pinActionUnpins(menuRowID: row.id, isPinned: row.isPinned),
            singleTarget: !model.selection.contains(row.id) || model.selection.count == 1, isSecure: row.isSecure,
            targetRows: model.menuTargetRows(menuRowID: row.id))
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .separator:
                Divider()
            case .item(let titleKey, let command, let isDestructive):
                Button(LibraryText.string(titleKey), role: isDestructive ? .destructive : nil) { act { model.perform(command) } }
            }
        }
    }

    /// Copy, Pin or Unpin and Delete on the hovered row (FR-003-38): the mouse path to the same commands as the context menu,
    /// acting on the row the same way. VoiceOver and keyboard users have the keys and the menu, so the strip is hidden from
    /// accessibility.
    @ViewBuilder
    private var hoverStrip: some View {
        if model.hoveredRowID == row.id {
            let actions = LibraryHover.actions(pinUnpins: model.pinActionUnpins(menuRowID: row.id, isPinned: row.isPinned))
            HStack(spacing: 2) {
                ForEach(actions) { action in
                    HoverStripButton(action: action) { act { model.perform(action.command) } }
                }
            }
            .padding(.horizontal, 4)
            .background(.regularMaterial, in: Capsule())
            // The strip, gaps included, takes the press: it never reaches the row's drag view beneath (FR-003-45).
            .contentShape(Capsule())
            .padding(4)
            .accessibilityHidden(true)
        }
    }

    /// Reports the hovered row's frame so the hover preview can sit beside it; only the hovered row reports.
    @ViewBuilder
    private var hoverFrameReader: some View {
        if model.hoveredRowID == row.id {
            GeometryReader { geometry in
                Color.clear.preference(key: HoveredRowFrameKey.self, value: geometry.frame(in: .named("libraryItems")))
            }
        }
    }

    /// A context-menu command acts on the row it was opened on (FR-003-22).
    private func act(_ command: () -> Void) {
        if !model.selection.contains(row.id) { model.select(id: row.id) }
        command()
    }
}

/// One button of the hover strip. The destructive glyph stays neutral until the pointer is on that button itself, so a
/// row that is merely under the pointer does not read as a warning (FR-003-38).
private struct HoverStripButton: View {
    let action: LibraryHoverAction
    let perform: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: perform) {
            Image(systemName: action.symbol).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(action.isDestructive ? (isHovered ? Color.red : Color.secondary) : Color.primary)
        .onHover { isHovered = $0 }
        .help(LibraryText.string(action.titleKey))
    }
}

private struct HoveredRowFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private extension View {
    func rowInteraction(model: LibraryViewModel, row: LibraryRowPresentation, stripAlignment: Alignment, dragOut: ShelfDragOut) -> some View {
        modifier(RowInteraction(model: model, row: row, stripAlignment: stripAlignment, dragOut: dragOut))
    }
}

func symbolName(for kind: ItemKind) -> String {
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
    selected ? DesignToken.selectionFill : (cursor ? DesignToken.cursorFill : Color.clear)
}

private extension LibraryRowPresentation {
    /// Whether `StatusBadges` would draw anything; an empty badge row takes no room in a list row.
    var hasStatusBadges: Bool {
        isPinned || hasTrigger || hasShortcut || isSecure || missingBadge != nil || unavailableBadge != nil
    }
}

private struct StatusBadges: View {
    let row: LibraryRowPresentation

    var body: some View {
        HStack(spacing: 4) {
            if row.isPinned { Image(systemName: "pin.fill") }
            if row.hasTrigger { Image(systemName: "text.cursor") }
            if row.hasShortcut { Image(systemName: "keyboard") }
            if row.isSecure { Image(systemName: "lock.fill") }
            if let badge = row.missingBadge ?? row.unavailableBadge {
                Text(verbatim: badge).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignToken.Radius.chip))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// The tag chips of a row. The chip is a neutral wash with the primary label colour, so it stays legible on the selection
/// fill (a plain `.quaternary` chip disappeared into it); selected, the wash is stronger.
private struct TagChips: View {
    let row: LibraryRowPresentation
    let selected: Bool

    var body: some View {
        ForEach(row.tagChips, id: \.self) { tag in
            Text(verbatim: tag).font(.caption2).foregroundStyle(.primary).padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(selected ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: DesignToken.Radius.chip))
        }
        if let overflow = row.tagOverflow { Text(verbatim: overflow).font(.caption2).foregroundStyle(.secondary) }
    }
}

struct LibraryListRow: View {
    let model: LibraryViewModel
    let row: LibraryRowPresentation
    let dragOut: ShelfDragOut

    var body: some View {
        let hovered = model.hoveredRowID == row.id
        let selected = model.selection.contains(row.id)
        // No stack spacing: gaps are explicit paddings, so an absent trailing cluster takes no room and the title
        // truncates by the width actually left, not by a character count (an empty subview still gets a gap from `spacing`).
        HStack(spacing: 0) {
            LibraryRowLead(model: model, row: row)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.primaryText).lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: row.secondaryText).font(.caption)
                        .foregroundStyle(selected ? DesignToken.onSelectionSecondary : Color.secondary).lineLimit(1)
                    TagChips(row: row, selected: selected)
                }
            }
            .padding(.leading, 10)
            Spacer(minLength: 8)
            // While the hover strip shows, its room is reserved here (the strip itself is the interaction overlay, above the
            // row's drag view) and the row's own badges and number give way to it, so the row never shows a second pin
            // beside the strip's Pin (FR-003-38). The title truncates before this slot, not under the strip.
            if hovered {
                Color.clear.frame(width: LibraryLayout.hoverStripReserve - 8, height: 1)
            } else if row.hasStatusBadges || row.shortcutBadge != nil {
                HStack(spacing: 6) {
                    if row.hasStatusBadges { StatusBadges(row: row) }
                    if let badge = row.shortcutBadge {
                        Text(verbatim: badge).font(.caption.monospaced())
                            .foregroundStyle(selected ? DesignToken.onSelectionSecondary : Color.primary.opacity(0.75))
                    }
                }
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: LibraryLayout.listRowHeight)
        .background(
            rowBackground(selected: selected, cursor: model.cursorID == row.id),
            in: RoundedRectangle(cornerRadius: DesignToken.Radius.row)
        )
        .rowInteraction(model: model, row: row, stripAlignment: .trailing, dragOut: dragOut)
    }
}

/// The lead slot of a list row (FR-003-07): always `LibraryLayout.listLeadSize` square. Images and screenshots show their
/// thumbnail; every other row, and an image whose thumbnail has not loaded, shows its kind icon in the same tile, so
/// every row's text starts at the same edge. Files, folders and bundles show the kind icon: the presentation carries no
/// file path to ask the system for a Finder icon.
private struct LibraryRowLead: View {
    let model: LibraryViewModel
    let row: LibraryRowPresentation
    @State private var thumbnail: NSImage?

    var body: some View {
        let side = LibraryLayout.listLeadSize
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: symbolName(for: row.kind)).foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.control))
        .accessibilityHidden(true)
        .task(id: row.id) {
            thumbnail = nil
            guard row.kind == .image || row.kind == .screenshot else { return }
            if let data = await model.thumbnail(for: row.id, size: .grid) { thumbnail = NSImage(data: data) }
        }
    }
}

struct LibraryGridCell: View {
    let model: LibraryViewModel
    let row: LibraryRowPresentation
    let dragOut: ShelfDragOut
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
            .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.control))
            Text(verbatim: row.primaryText).font(.caption).lineLimit(2)
            HStack(spacing: 4) {
                StatusBadges(row: row)
                if let badge = row.shortcutBadge { Text(verbatim: badge).font(.caption2.monospaced()).foregroundStyle(Color.primary.opacity(0.75)) }
            }
        }
        .padding(6)
        .background(
            rowBackground(selected: model.selection.contains(row.id), cursor: model.cursorID == row.id),
            in: RoundedRectangle(cornerRadius: DesignToken.Radius.row)
        )
        .task(id: row.id) {
            guard row.kind == .image || row.kind == .screenshot else { return }
            if let data = await model.thumbnail(for: row.id, size: .grid) { thumbnail = NSImage(data: data) }
        }
        .rowInteraction(model: model, row: row, stripAlignment: .topTrailing, dragOut: dragOut)
    }
}
