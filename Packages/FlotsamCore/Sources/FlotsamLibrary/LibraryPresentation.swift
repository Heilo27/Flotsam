import FlotsamBase
import FlotsamStorage
import Foundation

/// A list row or grid cell, already formatted (FR-003-07, FR-003-21). Pure: the same row, position and clock give the
/// same presentation, so it is tested without a view.
public struct LibraryRowPresentation: Equatable, Identifiable {
    public static let maximumTagChips = 3
    /// VoiceOver reads at most this many characters of the primary line (FR-003-21).
    public static let accessibilityPrimaryLimit = ItemSpeech.primaryLimit

    public let id: UUID
    public let kind: ItemKind
    public let primaryText: String
    /// Source app and relative time; the tag chips follow it.
    public let secondaryText: String
    public let tagChips: [String]
    /// The "+n" after the chips, or nil when every tag fits.
    public let tagOverflow: String?
    public let isPinned: Bool
    public let hasTrigger: Bool
    public let hasShortcut: Bool
    /// The files this item references are all gone: the row shows the "Missing" badge (FR-003-07).
    public let isMissing: Bool
    /// The badge's text (`ui.library.missing`), nil when the item is not missing.
    public let missingBadge: String?
    /// The "⌘1" to "⌘9" badge: only the first nine visible rows have one.
    public let shortcutBadge: String?
    public let accessibilityLabel: String

    public init(row: ItemRow, position: Int, now: Date) {
        id = row.id
        kind = row.kind
        primaryText = row.primaryLine
        isPinned = row.isPinned
        hasTrigger = row.hasTrigger
        hasShortcut = row.hasShortcut
        isMissing = row.isMissing
        missingBadge = row.isMissing ? LibraryText.string("ui.library.missing") : nil
        shortcutBadge = (0..<9).contains(position) ? "⌘\(position + 1)" : nil
        tagChips = Array(row.tagNames.prefix(Self.maximumTagChips))
        let overflow = row.tagNames.count - Self.maximumTagChips
        tagOverflow = overflow > 0 ? LibraryText.format("ui.library.tagOverflow", overflow) : nil

        let relative = ItemSpeech.relativeTime(row.lastCopiedAt, now: now)
        secondaryText = [row.sourceName, relative].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")

        // The Missing badge is read after the shared label (kind, primary line, source, age, pinned) (FR-003-07, FR-003-21).
        accessibilityLabel = [ItemSpeech.label(for: row, now: now), missingBadge].compactMap { $0 }.joined(separator: ", ")
    }
}

/// One selectable row of the sidebar (FR-003-12).
public struct SidebarEntry: Equatable, Identifiable {
    public enum Section: Sendable, Equatable { case top, types, tags, apps }

    public let filter: LibraryFilter
    public let section: Section
    public let title: String
    public let count: Int
    /// A tag with no items is dimmed, not hidden (FR-003-12).
    public let isDimmed: Bool

    public var id: LibraryFilter { filter }

    /// The sidebar in order: All, Pinned; the types that have items; tags alphabetically; the top apps by count. The
    /// query layer already orders tags and caps apps (`SidebarCounts`), so this only labels them.
    public static func entries(from counts: SidebarCounts) -> [SidebarEntry] {
        var entries = [
            SidebarEntry(filter: .all, section: .top, title: LibraryText.string("ui.library.sidebarAll"), count: counts.all, isDimmed: false),
            SidebarEntry(filter: .pinned, section: .top, title: LibraryText.string("ui.library.sidebarPinned"), count: counts.pinned, isDimmed: false),
        ]
        for kind in ItemKind.allCases {
            guard let count = counts.kinds[kind], count > 0 else { continue }
            entries.append(SidebarEntry(filter: .kind(kind), section: .types, title: LibraryText.typeTitle(kind), count: count, isDimmed: false))
        }
        for tag in counts.tags {
            entries.append(SidebarEntry(filter: .tag(tag.id), section: .tags, title: tag.name, count: tag.count, isDimmed: tag.count == 0))
        }
        for app in counts.apps {
            entries.append(SidebarEntry(filter: .sourceApp(app.identity), section: .apps, title: appTitle(app), count: app.count, isDimmed: false))
        }
        return entries
    }

    private static func appTitle(_ app: SidebarCounts.AppCount) -> String {
        switch app.identity {
        case .anotherDevice: LibraryText.string("ui.library.appAnotherDevice")
        case .unknown: LibraryText.string("ui.library.appUnknown")
        case .bundle(let id): app.name ?? id
        }
    }
}

/// The footer (FR-003-11, FR-003-18): the three most relevant keys, the count, and the copy-only notice.
public struct LibraryFooter: Equatable {
    public struct Hint: Equatable {
        public let key: String
        public let label: String
    }

    public let hints: [Hint]
    public let countText: String
    /// "Press ⌘V to paste" when Accessibility is off; "Select one item to paste" while several rows are selected.
    public let notice: String?
    /// The active sort's name, shown beside the count (FR-004-12).
    public let sortName: String

    public init(totalCount: Int, selectionCount: Int, isPreviewOpen: Bool, isAccessibilityTrusted: Bool, sort: LibrarySort) {
        sortName = LibraryText.sortName(sort)
        let multi = selectionCount >= 2
        if multi {
            hints = [Hint(key: LibraryText.string("ui.library.keyEsc"), label: LibraryText.string("ui.library.hintClearSelection"))]
            countText = LibraryText.selectedCount(selectionCount)
            notice = LibraryText.string("ui.library.footerMultiDisabled")
            return
        }
        let preview = Hint(
            key: LibraryText.string(isPreviewOpen ? "ui.library.keyEsc" : "ui.library.keySpace"),
            label: LibraryText.string(isPreviewOpen ? "ui.library.hintClose" : "ui.library.hintPreview"))
        let paste = Hint(key: LibraryText.string("ui.library.keyReturn"), label: LibraryText.string("ui.library.hintPaste"))
        let secondary = isAccessibilityTrusted
            ? Hint(key: LibraryText.string("ui.library.keyOptionReturn"), label: LibraryText.string("ui.library.hintPlain"))
            : Hint(key: LibraryText.string("ui.library.keyShiftReturn"), label: LibraryText.string("ui.library.hintCopy"))
        hints = [paste, secondary, preview]
        countText = LibraryText.itemCount(totalCount)
        notice = isAccessibilityTrusted ? nil : LibraryText.string("ui.library.footerCopyOnly")
    }
}
