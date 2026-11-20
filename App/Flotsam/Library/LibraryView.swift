import AppKit
import FlotsamBase
import FlotsamLibrary
import SwiftUI

/// The Library panel's content (FR-003-05): search field on top, sidebar on the left, list or grid in the middle, the
/// preview pane on the right when open (Compact: in place of the list), the footer at the bottom. All state and behaviour live in `LibraryViewModel`.
struct LibraryView: View {
    let model: LibraryViewModel
    let organize: OrganizeCoordinator
    let dragOut: ShelfDragOut
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
                    LibraryPreviewView(preview: model.preview)
                        .frame(minWidth: 200, idealWidth: 280, maxWidth: 360)
                case .replacesList:
                    // Compact: the preview takes the list's place and the sidebar stays; ↑/↓ still move the selection. `LibraryColumns`
                    // only says this while a row is selected in a loaded list, so the empty, no-results and error messages stay visible.
                    LibraryPreviewView(preview: model.preview)
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            LibraryFooterView(model: model)
        }
        // The panel's transparent title bar (full-size content) would otherwise add its height as a dead band above the
        // search row; the window buttons are hidden, so the row can use that space.
        .ignoresSafeArea(.container, edges: .top)
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

    /// The search row: the field in a visible rounded container that shows the focus ring, and the grid/list toggle beside it.
    private var searchField: some View {
        let toggleLabel = LibraryText.string(model.viewMode == .list ? "ui.library.viewGrid" : "ui.library.viewList")
        return HStack(spacing: 8) {
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
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            // The strongest control in the header (DESIGN 2.1): the shared field chrome reads as a field in both appearances.
            .fieldChrome(isActive: searchFocused, cornerRadius: 8)
            Button {
                model.toggleViewMode()
            } label: {
                Image(systemName: model.viewMode == .list ? "square.grid.2x2" : "list.bullet")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(toggleLabel)
            .accessibilityLabel(toggleLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            // Blank until the load has run for 150 ms (FR-003-50), so a fast load never flashes a spinner.
            BusyView(isVisible: model.busy.isVisible, isSearching: !model.searchText.isEmpty)
        case .failed(let error):
            LibraryStateView(
                symbol: "exclamationmark.triangle", title: LibraryText.string(LibraryText.errorTitle), message: FlotsamStrings.message(for: error),
                buttonTitle: LibraryText.string(LibraryText.retryButton)
            ) { Task { await model.retry() } }
        case .loaded:
            if model.isHistoryEmpty {
                LibraryStateView(
                    symbol: "doc.on.clipboard", title: LibraryText.string(LibraryText.emptyTitle), message: LibraryText.string(LibraryText.emptyBody),
                    buttonTitle: nil, action: {})
            } else if let tagName = model.emptyTagName {
                LibraryStateView(
                    symbol: "tag", title: LibraryText.emptyTagTitle(name: tagName), message: LibraryText.string(LibraryText.emptyTagBody),
                    buttonTitle: nil, action: {})
            } else if model.isNoResults {
                LibraryStateView(
                    symbol: "magnifyingglass", title: LibraryText.noResultsTitle(query: model.searchText),
                    message: LibraryText.string(LibraryText.noResultsBody),
                    buttonTitle: model.searchText.isEmpty ? nil : LibraryText.string(LibraryText.clearSearchButton)
                ) { model.setSearchText(String()) }
            } else {
                LibraryItemsView(model: model, dragOut: dragOut)
                    // A search or filter over rows already on screen: the rows stay, the badge says it is working.
                    .busyBadge(isVisible: model.busy.isVisible, isSearching: !model.searchText.isEmpty)
            }
        }
    }
}

/// Empty history, no results and load failure share one shape: a title, a line, an optional button (FR-003-17).
struct LibraryStateView: View {
    let symbol: String
    let title: String
    let message: String
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
                .padding(.bottom, 2)
            Text(verbatim: title).font(.headline)
            Text(verbatim: message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let buttonTitle {
                Button(buttonTitle, action: action).buttonStyle(.bordered).controlSize(.regular).padding(.top, 6)
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
        // The sidebar is a scroll view whose content (about 570 pt with Types open) is taller than the 760 x 480 default's
        // viewport (about 400 pt), so it rests scrolled to the top with its bottom edge somewhere in the list. Every line
        // (row or header) is one `lineHeight`, the viewport is a whole number of lines, and scrolling snaps to a line,
        // so the edge never slices a row: it falls between two (TASK-529 round 3; the round 2 margins and fade only
        // changed where the last row ended at the far end of the scroll, never what the edge cut at rest).
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section(.top, title: nil, entries)
                    section(.types, title: LibraryText.string(LibraryText.sectionTypes), entries)
                    section(.tags, title: LibraryText.string(LibraryText.sectionTags), entries)
                    section(.apps, title: LibraryText.string(LibraryText.sectionApps), entries)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 8, for: .scrollContent)
            .contentMargins(.top, Self.topMargin, for: .scrollContent)
            .frame(height: Self.snappedHeight(fitting: proxy.size.height))
        }
    }

    /// One sidebar line: a row or a section header (DESIGN 3.3 Library): tight, so the results list stays the dominant column.
    private static let lineHeight: CGFloat = 24
    private static let topMargin: CGFloat = 4

    /// The tallest viewport at most `available` high that holds a whole number of lines (at least one).
    static func snappedHeight(fitting available: CGFloat) -> CGFloat {
        let lines = max(((available - topMargin) / lineHeight).rounded(.down), 1)
        return topMargin + lines * lineHeight
    }

    @ViewBuilder
    private func section(_ section: SidebarEntry.Section, title: String?, _ entries: [SidebarEntry]) -> some View {
        let inSection = entries.filter { $0.section == section }
        if !inSection.isEmpty {
            let collapsed = section == .types && model.sidebarTypesCollapsed
            if let title {
                if section == .types { typesHeader(title: title, collapsed: collapsed) } else { header(title) }
            }
            // A folded Types section still shows the type that is the active filter, so the highlight never disappears.
            ForEach(collapsed ? inSection.filter { $0.filter == model.filter } : inSection) { entry in
                Button { model.select(filter: entry.filter) } label: {
                    HStack {
                        Text(verbatim: entry.title).lineLimit(1)
                        Spacer(minLength: 4)
                        // The counts are the whole history's, so they go while the search has text (FR-003-12).
                        if model.showsSidebarCounts {
                            Text(verbatim: entry.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .font(.system(size: 13))
                    .opacity(entry.isDimmed ? 0.5 : 1)
                    .padding(.horizontal, 6)
                    .frame(height: Self.lineHeight)
                    .background(model.filter == entry.filter ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.filter == entry.filter ? .isSelected : [])
                .contextMenu { tagMenu(for: entry) }
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(verbatim: title).font(.caption).foregroundStyle(.secondary).padding(.bottom, 3).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: Self.lineHeight, maxHeight: Self.lineHeight, alignment: .bottomLeading)
    }

    /// The Types header folds the section (FR-003-12); the choice is remembered in `library.sidebarTypesCollapsed`.
    private func typesHeader(title: String, collapsed: Bool) -> some View {
        let tip = LibraryText.string(collapsed ? LibraryText.typesShow : LibraryText.typesHide)
        return Button { model.toggleSidebarTypes() } label: {
            HStack(spacing: 4) {
                Text(verbatim: title)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(collapsed ? 0 : 90))
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 3).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: Self.lineHeight, maxHeight: Self.lineHeight, alignment: .bottomLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
        .accessibilityLabel(title)
        .accessibilityHint(tip)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The bottom fade shared by the sidebar and the results list (FR-003-05): rows dissolve into the footer instead of being
/// cut off by it.
enum LibraryScrollFade {
    static let height: CGFloat = 16
}

extension View {
    /// Fades the last `LibraryScrollFade.height` points to clear. Pair it with a bottom content margin of at least that, so the
    /// final row can be scrolled out of the fade.
    func fadingBottomEdge() -> some View {
        mask(
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: LibraryScrollFade.height)
            })
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
            // The first hint is the leading action (Return Paste, or Return Start paste queue): stronger than the rest. Keycaps are in
            // the system font, not monospace.
            ForEach(Array(footer.hints.enumerated()), id: \.element.key) { index, hint in
                let leading = index == 0
                HStack(spacing: 4) {
                    Text(verbatim: hint.key).font(.caption.weight(leading ? .semibold : .regular))
                        .padding(.horizontal, 4)
                        .background(leading ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                    Text(verbatim: hint.label).font(.caption.weight(leading ? .semibold : .regular))
                        .foregroundStyle(leading ? Color.primary : Color.secondary)
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
