import AppKit
import FlotsamBase
import FlotsamLibrary
import SwiftUI

/// The Library panel's content (FR-003-05): search field on top, sidebar on the left, list or grid in the middle, the
/// preview pane on the right when open (Compact: in place of the list), the footer at the bottom. All state and behaviour live in `LibraryViewModel`.
struct LibraryView: View {
    let model: LibraryViewModel
    let organize: OrganizeCoordinator
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            HStack(spacing: 0) {
                LibrarySidebar(model: model, organize: organize)
                    .frame(width: 170)
                Divider()
                // Which columns exist is `LibraryColumns`' decision (FR-003-06); the view only draws it.
                let columns = model.columns
                switch columns.preview {
                case .hidden:
                    content
                case .rightPane:
                    content
                    Divider()
                    LibraryPreviewView(model: model)
                        .frame(minWidth: 200, idealWidth: 280, maxWidth: 360)
                case .replacesList:
                    // Compact: the preview takes the list's place and the sidebar stays; ↑/↓ still move the selection.
                    LibraryPreviewView(model: model)
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            LibraryFooterView(model: model)
        }
        .overlay { OrganizeOverlayHost(organize: organize, model: model) }
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if !organize.isOverlayOpen { searchFocused = true }
        }
        // The overlay's field had the focus; hand it back to search when the overlay closes.
        .onChange(of: organize.isOverlayOpen) { _, open in
            if !open { searchFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(
                LibraryText.string(LibraryText.searchPlaceholder),
                text: Binding(get: { model.searchText }, set: { model.setSearchText($0) })
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($searchFocused)
            .accessibilityLabel(LibraryText.string(LibraryText.searchPlaceholder))
            Button {
                model.toggleViewMode()
            } label: {
                Image(systemName: model.viewMode == .list ? "square.grid.2x2" : "list.bullet")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(LibraryText.string(model.viewMode == .list ? "ui.library.viewGrid" : "ui.library.viewList"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            LibraryStateView(
                title: LibraryText.string(LibraryText.errorTitle), message: FlotsamStrings.message(for: error),
                buttonTitle: LibraryText.string(LibraryText.retryButton)
            ) { Task { await model.retry() } }
        case .loaded:
            if model.isHistoryEmpty {
                LibraryStateView(
                    title: LibraryText.string(LibraryText.emptyTitle), message: LibraryText.string(LibraryText.emptyBody),
                    buttonTitle: nil, action: {})
            } else if model.isNoResults {
                LibraryStateView(
                    title: LibraryText.noResultsTitle(query: model.searchText),
                    message: LibraryText.string(LibraryText.noResultsBody),
                    buttonTitle: model.searchText.isEmpty ? nil : LibraryText.string(LibraryText.clearSearchButton)
                ) { model.setSearchText(String()) }
            } else {
                LibraryItemsView(model: model)
            }
        }
    }
}

/// Empty history, no results and load failure share one shape: a title, a line, an optional button (FR-003-17).
struct LibraryStateView: View {
    let title: String
    let message: String
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(verbatim: title).font(.headline)
            Text(verbatim: message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let buttonTitle {
                Button(buttonTitle, action: action).padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct LibrarySidebar: View {
    let model: LibraryViewModel
    let organize: OrganizeCoordinator

    var body: some View {
        let entries = model.sidebarEntries
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                section(.top, title: nil, entries)
                section(.types, title: LibraryText.string(LibraryText.sectionTypes), entries)
                section(.tags, title: LibraryText.string(LibraryText.sectionTags), entries)
                section(.apps, title: LibraryText.string(LibraryText.sectionApps), entries)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func section(_ section: SidebarEntry.Section, title: String?, _ entries: [SidebarEntry]) -> some View {
        let inSection = entries.filter { $0.section == section }
        if !inSection.isEmpty {
            if let title {
                Text(verbatim: title).font(.caption).foregroundStyle(.secondary).padding(.top, 8).padding(.horizontal, 6)
            }
            ForEach(inSection) { entry in
                Button { model.select(filter: entry.filter) } label: {
                    HStack {
                        Text(verbatim: entry.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(verbatim: entry.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .opacity(entry.isDimmed ? 0.5 : 1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(model.filter == entry.filter ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.filter == entry.filter ? .isSelected : [])
                .contextMenu { tagMenu(for: entry) }
            }
        }
    }
}

extension LibrarySidebar {
    /// Rename, Colour and Delete on a tag entry (FR-004-04); the other entries have no menu.
    @ViewBuilder
    fileprivate func tagMenu(for entry: SidebarEntry) -> some View {
        if case .tag(let id) = entry.filter {
            Button(LibraryText.string(LibraryText.menuRename)) { organize.renameTag(id: id, currentName: entry.title) }
            Menu(LibraryText.string(LibraryText.menuColor)) {
                ForEach(TagColor.allCases, id: \.self) { color in
                    Button(LibraryText.colorName(color)) { organize.recolorTag(id: id, to: color) }
                }
            }
            Divider()
            Button(LibraryText.string(LibraryText.menuDelete)) {
                organize.deleteTag(id: id, name: entry.title, itemCount: entry.count)
            }
        }
    }
}

struct LibraryFooterView: View {
    let model: LibraryViewModel

    var body: some View {
        let footer = model.footer()
        HStack(spacing: 14) {
            ForEach(footer.hints, id: \.key) { hint in
                HStack(spacing: 4) {
                    Text(verbatim: hint.key).font(.caption.monospaced())
                        .padding(.horizontal, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    Text(verbatim: hint.label).font(.caption)
                }
            }
            if let notice = footer.notice {
                Text(verbatim: notice).font(.caption).foregroundStyle(.orange)
            }
            if let enableLabel = footer.enableLabel {
                Button(enableLabel) { model.enableAccessibility() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer()
            // The active sort, then the count (FR-004-12, FR-003-18); both come from `LibraryFooter`.
            Text(verbatim: footer.sortName).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: footer.countText).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        // Picks up a grant made in System Settings without a relaunch (FR-008-14). The hosting view outlives every
        // hide, so the id includes `isShown`: the poll runs only while the copy-only footer shows on a shown panel,
        // and restarts on the next open.
        .task(id: footer.enableLabel != nil && model.isShown) {
            guard footer.enableLabel != nil else { return }
            await model.watchAccessibility()
        }
    }
}
