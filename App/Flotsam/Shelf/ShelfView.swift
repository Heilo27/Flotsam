import AppKit
import FlotsamBase
import FlotsamShelf
import FlotsamStorage
import SwiftUI
import UniformTypeIdentifiers

/// The Shelf's contents (FR-006-06, FR-006-07, FR-006-09, FR-006-19): the Pinned and Recent sections as a vertical list,
/// or one horizontal strip for the bottom placement, the empty state, and a close button. What a card shows is decided
/// by `ShelfCardPresentation` and what a click does by `ShelfModel`; this only draws and forwards.
struct ShelfView: View {
    let model: ShelfModel
    let placement: ShelfPlacement
    let thumbnail: @Sendable (UUID) async -> Data?
    let close: @MainActor () -> Void

    private var horizontal: Bool { ShelfLayout.isHorizontal(placement) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel(Text(verbatim: ShelfText.string(ShelfText.close)))
        }
    }

    @ViewBuilder private var content: some View {
        let sections = model.sections()
        if sections.isEmpty {
            Text(verbatim: ShelfText.string(ShelfText.empty))
                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if horizontal {
            ScrollView(.horizontal) {
                LazyHStack(spacing: ShelfLayout.cardSpacing) {
                    ForEach(sections.flatMap(\.cards)) { card in cardView(card) }
                }.padding(ShelfLayout.contentPadding)
            }
        } else {
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
        }
    }

    private func cardView(_ card: ShelfCardPresentation) -> some View {
        ShelfCardView(
            card: card, model: model, size: ShelfLayout.cardSize(for: placement), horizontal: horizontal,
            thumbnail: thumbnail)
    }
}

private struct ShelfCardView: View {
    let card: ShelfCardPresentation
    let model: ShelfModel
    let size: CGSize
    let horizontal: Bool
    let thumbnail: @Sendable (UUID) async -> Data?
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
                if let source = card.sourceName {
                    Text(verbatim: source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06)))
        .overlay(alignment: .topTrailing) {
            if card.isPinned { Image(systemName: "pin.fill").font(.caption2).padding(4).accessibilityHidden(true) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.doubleClick(card.id) }
        .onTapGesture { model.click(card.id, modifiers: LibraryKeyTranslator.chordModifiers(NSEvent.modifierFlags)) }
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
