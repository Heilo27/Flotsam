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

    private static let pillFadeWidth: CGFloat = 36

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if model.showsSearch { searchHeader }
                content
            }
            if model.isDropTargeted { dropZone }
            if model.isShareZoneShown { shareZone }
            // The panel's close button: a bare cross, so it never reads as the search field's round clear button (FR-006-22).
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .help(ShelfText.string(ShelfText.close))
            .accessibilityLabel(Text(verbatim: ShelfText.string(ShelfText.close)))
        }
        // Ages the cards' VoiceOver labels while the Shelf is open (FR-006-48). The model owns the watch task and cancels
        // it on a hide; the key restarts it on the next open or card change.
        .task(id: model.relativeTimeWatchKey) { await model.runRelativeTimeWatch() }
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
            // The clear button exists only while the field has text.
            if !model.searchText.isEmpty {
                Button { model.setSearchText(String()) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(ShelfText.string(ShelfText.clearSearch))
                .accessibilityLabel(ShelfText.string(ShelfText.clearSearch))
            }
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
            // Room at the end, so the last pill clears the fade once the row is scrolled all the way.
            .padding(.trailing, Self.pillFadeWidth)
        }
        .frame(height: ShelfLayout.searchRowHeight)
        // A pill cut off at the trailing edge fades out instead of ending mid-word, which says the row scrolls.
        .mask(
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.pillFadeWidth)
            })
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

    /// The share zone while a drag of Flotsam's own clips is over the panel (FR-006-42): a strip on the trailing edge of
    /// the horizontal placements and along the bottom of the vertical ones, where `ShelfLayout.shareZone` tests the
    /// pointer. It never takes clicks; the panel's drag destination takes the drop.
    private var shareZone: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        let label = VStack(spacing: 4) {
            Image(systemName: "square.and.arrow.up")
            Text(verbatim: ShelfText.string(ShelfText.shareZone)).font(.caption.bold()).multilineTextAlignment(.center)
        }
        .foregroundStyle(Color.accentColor)
        .padding(4)
        return shape
            .fill(Color.accentColor.opacity(model.isShareTargeted ? 0.35 : 0.15))
            .overlay(shape.strokeBorder(Color.accentColor, lineWidth: model.isShareTargeted ? 3 : 1.5))
            .overlay { label }
            .frame(
                width: horizontal ? ShelfLayout.shareZoneThickness : nil,
                height: horizontal ? nil : ShelfLayout.shareZoneThickness)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: horizontal ? .trailing : .bottom)
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
        var size = ShelfLayout.cardSize(for: placement, showsSearch: model.showsSearch)
        // The vertical placements size a text card to its text (FR-006-07); the horizontal strip keeps its fixed height.
        if !horizontal { size.height = card.verticalHeight }
        return ShelfCardView(card: card, model: model, size: size, horizontal: horizontal, thumbnail: thumbnail, dragOut: dragOut)
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

    @Environment(\.colorScheme) private var colorScheme
    private var selected: Bool { model.selection.contains(card.id) }
    private let shape = RoundedRectangle(cornerRadius: 10)

    /// Header row over a content area; the header never overlaps the content (hill-climb r1, TASK-529).
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background {
            // A raised surface: an opaque card fill, a hairline edge that also separates it on a dark panel, and a soft shadow.
            // The selected card is a 2 pt accent ring and nothing else: no tint over the card (FR-006-07). In dark the hairline is
            // brighter, so the card still separates from the panel.
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    shape.strokeBorder(
                        selected ? Color.accentColor : Color.primary.opacity(colorScheme == .dark ? 0.30 : 0.14),
                        lineWidth: selected ? 2 : (colorScheme == .dark ? 1 : 0.5)))
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
        }
        .overlay {
            // A dropped card flashes for `ShelfLayout.dropHighlightDuration` (FR-006-15).
            if model.highlightedItemId == card.id {
                shape.strokeBorder(Color.accentColor, lineWidth: 2)
            }
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

    /// Source app icon, app name, pin badge and age: one 16 pt row.
    private var header: some View {
        HStack(spacing: 4) {
            Image(nsImage: SourceAppIcons.icon(forBundleId: card.sourceBundleId))
                .resizable().frame(width: 14, height: 14).accessibilityHidden(true)
            if let source = card.sourceName {
                Text(verbatim: source).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if card.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true) }
            Text(verbatim: card.age).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
        }
        .frame(height: 16)
    }

    @ViewBuilder private var content: some View {
        switch card.visual {
        case .thumbnail:
            // Full bleed across the content area, clipped to its own rounded rectangle so a wide or tall picture can
            // never run past the card edge. `Color.clear.overlay` takes the proposed size, which `scaledToFill` would not.
            Color.clear
                .overlay {
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                    else { Image(systemName: symbolName(for: card.kind)).font(.title2).foregroundStyle(.secondary) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .swatch:
            // A big swatch with its value under it.
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 6).fill(Self.color(from: card.text) ?? Color.secondary)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let text = card.text { Text(verbatim: text).font(.caption.monospaced()).lineLimit(1) }
            }
        case .fileIcon, .stackedIcon, .secure:
            HStack(alignment: .top, spacing: 8) {
                picture.frame(width: 36, height: 36)
                textColumn
            }
        case .kindIcon(let kind):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: symbolName(for: kind)).font(.caption).foregroundStyle(.secondary).frame(width: 14)
                textColumn
            }
        }
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let text = card.text { Text(verbatim: text).font(.callout).lineLimit(ShelfLayout.cardTextLineLimit) }
            if card.isMissing {
                Text(verbatim: ShelfText.string(ShelfText.missing)).font(.caption2).foregroundStyle(.red)
            }
            if let unavailable = card.unavailableBadge {
                Text(verbatim: unavailable).font(.caption2).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The picture of the file, bundle and secure cards (the others draw their own content above).
    @ViewBuilder private var picture: some View {
        switch card.visual {
        case .fileIcon:
            Image(nsImage: Self.fileIcon(named: card.text, folder: card.kind == .folder)).resizable().scaledToFit()
        case .stackedIcon(let count):
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbolName(for: .bundle)).font(.title2).foregroundStyle(.secondary)
                Text(verbatim: String(count)).font(.caption2.bold()).padding(2)
            }
        default:
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

/// Source app icons for the card header, one lookup per app. The app may be gone from this Mac, and then the card shows a
/// generic app glyph; no disk access happens per frame, because a drawn icon is cached by bundle identifier.
@MainActor
private enum SourceAppIcons {
    private static var cache: [String: NSImage] = [:]
    private static let generic: NSImage = NSWorkspace.shared.icon(for: .applicationBundle)

    static func icon(forBundleId bundleId: String?) -> NSImage {
        guard let bundleId, !bundleId.isEmpty else { return generic }
        if let cached = cache[bundleId] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? generic
        cache[bundleId] = icon
        return icon
    }
}
