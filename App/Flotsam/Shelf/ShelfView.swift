import AppKit
import FlotsamBase
import FlotsamShelf
import FlotsamStorage
import SwiftUI
import UniformTypeIdentifiers

/// The Shelf's contents (FR-006-06, FR-006-07, FR-006-09, FR-006-19): the Pinned and Recent sections as a vertical list,
/// or one horizontal strip for the bottom and top-centre placements, the empty state, and a close button. What a card shows is decided
/// by `ShelfCardPresentation` and what a click does by `ShelfModel`; this only draws and forwards.
struct ShelfView: View {
    let model: ShelfModel
    let placement: ShelfPlacement
    let thumbnail: @Sendable (UUID) async -> Data?
    let dragOut: ShelfDragOut
    let close: @MainActor () -> Void

    @FocusState private var searchFocused: Bool

    private var horizontal: Bool { ShelfLayout.isHorizontal(placement) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if model.showsSearch { searchHeader }
                content
            }
            if model.isDropTargeted { dropZone }
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel(Text(verbatim: ShelfText.string(ShelfText.close)))
        }
    }

    /// The search field and type pills of a sticky Shelf (FR-006-22): one row in the horizontal placements, the field
    /// above the pills in the vertical ones. The right edge stays clear of the close button.
    private var searchHeader: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            searchField
            typePills
        }
        .padding(.leading, ShelfLayout.contentPadding)
        .padding(.trailing, ShelfLayout.contentPadding + 24)
        .frame(height: ShelfLayout.searchHeaderHeight(for: placement))
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(
                ShelfText.string(ShelfText.searchPlaceholder),
                text: Binding(get: { model.searchText }, set: { model.setSearchText($0) })
            )
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .accessibilityLabel(ShelfText.string(ShelfText.searchPlaceholder))
        }
        .frame(width: horizontal ? 220 : nil, height: ShelfLayout.searchRowHeight)
    }

    /// All, then each type that has an item, in the Library's Types order. A pill is a button, so it is also reachable
    /// by Tab and VoiceOver; ⌥↑ / ⌥↓ step through them without leaving the field.
    private var typePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                pill(title: ShelfText.string(ShelfText.filterAll), kind: nil)
                ForEach(model.availableKinds, id: \.self) { kind in
                    pill(title: ShelfText.typeTitle(kind), kind: kind)
                }
            }
        }
        .frame(height: ShelfLayout.searchRowHeight)
    }

    private func pill(title: String, kind: ItemKind?) -> some View {
        let selected = model.kindFilter == kind
        return Button { model.setKindFilter(kind) } label: {
            Text(verbatim: title).font(.caption).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The drop zone while an acceptable drag is over the panel (FR-006-12). It never takes clicks.
    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay { Text(verbatim: ShelfText.string(ShelfText.dropZone)).font(.callout.bold()).foregroundStyle(Color.accentColor) }
            .padding(4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Scrolls the highlighted card into view (FR-006-15). Keyed on the card ids as well as the highlight, because the
    /// card appears once the new row is loaded, which may be after the highlight is set.
    private struct ScrollKey: Equatable {
        let highlighted: UUID?
        let cardIds: [UUID]
    }

    private func scrollKey(_ sections: [ShelfSection]) -> ScrollKey {
        ScrollKey(highlighted: model.highlightedItemId, cardIds: sections.flatMap(\.cards).map(\.id))
    }

    private func reveal(_ key: ScrollKey, in proxy: ScrollViewProxy, anchor: UnitPoint) {
        guard let id = key.highlighted, key.cardIds.contains(id) else { return }
        withAnimation { proxy.scrollTo(id, anchor: anchor) }
    }

    @ViewBuilder private var content: some View {
        if model.orderedRows.isEmpty, model.loadState == .loading {
            // Blank until the load has run for 150 ms (FR-006-32): neither the empty text nor "No matches" is true yet.
            BusyView(isVisible: model.busy.isVisible, isSearching: model.isFiltering)
        } else {
            cardsOrState.busyBadge(isVisible: model.busy.isVisible, isSearching: model.isFiltering)
        }
    }

    @ViewBuilder private var cardsOrState: some View {
        let sections = model.sections()
        if sections.isEmpty && model.isFiltering {
            // A search or type filter that matches nothing; the empty-history text would be wrong here (FR-006-22).
            VStack(spacing: 4) {
                Text(verbatim: ShelfText.noResultsTitle(query: model.searchText)).font(.headline)
                Text(verbatim: ShelfText.string(ShelfText.noResultsBody)).font(.subheadline)
            }
            .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.isEmpty {
            Text(verbatim: ShelfText.string(ShelfText.empty))
                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if horizontal {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: ShelfLayout.cardSpacing) {
                        ForEach(sections.flatMap(\.cards)) { card in cardView(card) }
                    }.padding(ShelfLayout.contentPadding)
                }
                .id(queryIdentity)
                .onChange(of: scrollKey(sections)) { _, key in reveal(key, in: proxy, anchor: .leading) }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: ShelfLayout.cardSpacing) {
                        ForEach(sections) { section in
                            Text(verbatim: ShelfText.string(section.titleKey))
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(height: ShelfLayout.sectionHeaderHeight, alignment: .bottomLeading)
                            ForEach(section.cards) { card in cardView(card) }
                        }
                    }.padding(ShelfLayout.contentPadding)
                }
                .id(queryIdentity)
                .onChange(of: scrollKey(sections)) { _, key in reveal(key, in: proxy, anchor: .top) }
            }
        }
    }

    /// A new search or type filter starts the list at its first card (FR-006-22): the scroll view is rebuilt per query.
    private var queryIdentity: String { "\(model.kindFilter?.rawValue ?? "")|\(model.searchText)" }

    private func cardView(_ card: ShelfCardPresentation) -> some View {
        ShelfCardView(
            card: card, model: model, size: ShelfLayout.cardSize(for: placement, showsSearch: model.showsSearch), horizontal: horizontal,
            thumbnail: thumbnail, dragOut: dragOut)
    }
}

private struct ShelfCardView: View {
    let card: ShelfCardPresentation
    let model: ShelfModel
    let size: CGSize
    let horizontal: Bool
    let thumbnail: @Sendable (UUID) async -> Data?
    let dragOut: ShelfDragOut
    @State private var image: NSImage?

    private var selected: Bool { model.selection.contains(card.id) }

    var body: some View {
        let layout = horizontal ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            visual.frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                if let text = card.text { Text(verbatim: text).font(.callout).lineLimit(ShelfLayout.cardTextLineLimit) }
                if card.isMissing {
                    Text(verbatim: ShelfText.string(ShelfText.missing)).font(.caption2).foregroundStyle(.red)
                }
                if let unavailable = card.unavailableBadge {
                    Text(verbatim: unavailable).font(.caption2).foregroundStyle(.red)
                }
                if let source = card.sourceName {
                    Text(verbatim: source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06)))
        .overlay {
            // A dropped card flashes for `ShelfLayout.dropHighlightDuration` (FR-006-15).
            if model.highlightedItemId == card.id {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if card.isPinned { Image(systemName: "pin.fill").font(.caption2).padding(4).accessibilityHidden(true) }
        }
        .contentShape(Rectangle())
        .overlay {
            ShelfCardInteraction(
                onClick: { model.click(card.id, modifiers: $0) },
                onDoubleClick: { model.doubleClick(card.id) },
                prepareDrag: { dragOut.prepare(cardId: card.id) },
                beginDrag: { await dragOut.begin(from: $0, event: $1) })
        }
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: card.accessibilityLabel))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(verbatim: card.title(of: .paste))) { model.perform(.paste, on: card.id) }
        .accessibilityAction(named: Text(verbatim: card.title(of: .copy))) { model.perform(.copy, on: card.id) }
        .accessibilityAction(named: Text(verbatim: card.title(of: .togglePin))) { model.perform(.togglePin, on: card.id) }
        .task(id: card.id) {
            guard card.visual == .thumbnail, let data = await thumbnail(card.id) else { return }
            image = NSImage(data: data)
        }
    }

    @ViewBuilder private var visual: some View {
        switch card.visual {
        case .thumbnail:
            if let image { Image(nsImage: image).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 4)) }
            else { Image(systemName: symbolName(for: card.kind)).font(.title2).foregroundStyle(.secondary) }
        case .fileIcon:
            Image(nsImage: Self.fileIcon(named: card.text, folder: card.kind == .folder)).resizable().scaledToFit()
        case .stackedIcon(let count):
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbolName(for: .bundle)).font(.title2).foregroundStyle(.secondary)
                Text(verbatim: String(count)).font(.caption2.bold()).padding(2)
            }
        case .swatch:
            RoundedRectangle(cornerRadius: 6).fill(Self.color(from: card.text) ?? Color.secondary)
        case .kindIcon(let kind):
            Image(systemName: symbolName(for: kind)).font(.title2).foregroundStyle(.secondary)
        case .secure:
            Image(systemName: "lock.fill").font(.title2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var menu: some View {
        ForEach(Array(model.contextMenu(for: card.id).enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .item(let action, let titleKey):
                Button(ShelfText.string(titleKey)) { model.perform(action, on: card.id) }
            case .separator:
                Divider()
            }
        }
    }

    /// The system icon for the file type of `name` (no disk access: the file may be gone, and then it is Missing).
    private static func fileIcon(named name: String?, folder: Bool) -> NSImage {
        let type = folder ? UTType.folder : (name.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) } ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }

    /// A colour item's swatch; nil when its notation is not one `ColorChannels` reads.
    private static func color(from text: String?) -> Color? {
        ColorChannels(text: text).map(Color.init)
    }
}
