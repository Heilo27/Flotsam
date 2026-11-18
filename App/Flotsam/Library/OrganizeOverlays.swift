import FlotsamBase
import FlotsamLibrary
import FlotsamStorage
import SwiftUI

extension TagColor {
    /// System colours stand in for the design system's tag palette (FR-004-02).
    var swatch: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

/// The Organize overlays (FRD-004), drawn over the whole Library panel. A click on the dimmed area cancels, like Esc.
struct OrganizeOverlayHost: View {
    let organize: OrganizeCoordinator
    let model: LibraryViewModel

    var body: some View {
        if let overlay = organize.overlay {
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { organize.close() }
                    .accessibilityHidden(true)
                card(for: overlay)
            }
        }
    }

    @ViewBuilder
    private func card(for overlay: OrganizeOverlay) -> some View {
        switch overlay {
        case .confirm(let confirmation): ConfirmCard(organize: organize, confirmation: confirmation)
        case .tags: TagPickerCard(organize: organize, tags: model.sidebar?.tags ?? [])
        case .note: NoteCard(organize: organize)
        case .edit(_, let kind): EditCard(organize: organize, isRichText: kind == .richText)
        case .renameTag: RenameTagCard(organize: organize)
        }
    }
}

private extension View {
    func overlayCard() -> some View {
        padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .shadow(radius: 12)
    }
}

private struct ValidationLabel: View {
    let message: String?

    var body: some View {
        if let message {
            Text(verbatim: message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SaveCancelRow: View {
    let organize: OrganizeCoordinator

    var body: some View {
        HStack {
            Spacer()
            Button(LibraryText.string(LibraryText.buttonCancel)) { organize.close() }
            Button(LibraryText.string(LibraryText.buttonSave)) { organize.primaryAction() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct ConfirmCard: View {
    let organize: OrganizeCoordinator
    let confirmation: OrganizeConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: confirmation.message).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(LibraryText.string(LibraryText.buttonCancel)) { organize.close() }
                Button(confirmation.buttonTitle) { organize.primaryAction() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 320)
        .overlayCard()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct TagPickerCard: View {
    let organize: OrganizeCoordinator
    let tags: [SidebarCounts.TagCount]
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var organize = organize
        let matches = organize.matchingTags(in: tags)
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: LibraryText.string(LibraryText.tagsTitle)).font(.headline)
            TextField(LibraryText.string(LibraryText.tagFieldPlaceholder), text: $organize.tagQuery)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { organize.submitTagField() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matches, id: \.id) { tag in
                        TagRow(organize: organize, tag: tag)
                    }
                    if organize.canCreate(among: tags) {
                        Button { organize.createTag() } label: {
                            Label {
                                Text(verbatim: LibraryText.createTag(name: organize.trimmedQuery)).lineLimit(1)
                            } icon: { Image(systemName: "plus.circle") }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
            ValidationLabel(message: organize.validation)
        }
        .frame(width: 280)
        .overlayCard()
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct TagRow: View {
    let organize: OrganizeCoordinator
    let tag: SidebarCounts.TagCount

    var body: some View {
        let applied = organize.membership[tag.id] ?? 0
        let total = organize.selectionCount
        Button { organize.toggleTag(tag.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: applied == 0 ? "circle" : (applied >= total ? "checkmark.circle.fill" : "minus.circle.fill"))
                Circle().fill(TagColor(stored: tag.color).swatch).frame(width: 9, height: 9)
                Text(verbatim: tag.name).lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: tag.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(applied > 0 && applied >= total ? .isSelected : [])
    }
}

private struct NoteCard: View {
    let organize: OrganizeCoordinator
    @FocusState private var focused: Bool
    /// The counter appears only near the limit (FR-004-06). Limit, threshold and counting rule are Storage's
    /// (`IngestLimits`), so the counter agrees with what save accepts.
    private var length: Int { IngestLimits.noteLength(organize.draft) }

    var body: some View {
        @Bindable var organize = organize
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: LibraryText.string(LibraryText.noteTitle)).font(.headline)
            TextEditor(text: $organize.draft)
                .font(.body)
                .focused($focused)
                .frame(width: 320, height: 140)
                .scrollContentBackground(.hidden)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            if length >= IngestLimits.noteCounterThreshold {
                Text(verbatim: LibraryText.noteCounter(length)).font(.caption)
                    .foregroundStyle(length > IngestLimits.maxNoteCharacters ? .red : .secondary)
            }
            ValidationLabel(message: organize.validation)
            SaveCancelRow(organize: organize)
        }
        .overlayCard()
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct EditCard: View {
    let organize: OrganizeCoordinator
    let isRichText: Bool
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var organize = organize
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: LibraryText.string(LibraryText.editTitle)).font(.headline)
            TextEditor(text: $organize.draft)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isRichText {
                Text(verbatim: LibraryText.string(LibraryText.editFormattingRemoved)).font(.caption).foregroundStyle(.secondary)
            }
            ValidationLabel(message: organize.validation)
            SaveCancelRow(organize: organize)
        }
        .overlayCard()
        .padding(24)
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct RenameTagCard: View {
    let organize: OrganizeCoordinator
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var organize = organize
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: LibraryText.string(LibraryText.menuRename)).font(.headline)
            // Return is handled by the coordinator's key path, so there is no `onSubmit` here.
            TextField(LibraryText.string(LibraryText.menuRename), text: $organize.draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            ValidationLabel(message: organize.validation)
            SaveCancelRow(organize: organize)
        }
        .frame(width: 280)
        .overlayCard()
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
