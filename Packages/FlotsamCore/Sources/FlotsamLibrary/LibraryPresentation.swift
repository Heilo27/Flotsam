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
    /// The source app's bundle identifier, for the app icon that leads a text, link and code row (FR-003-07); nil when unknown.
    public let sourceBundleId: String?
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
    /// A secure clip: `primaryText` is the fixed mask (FR-003-07).
    public let isSecure: Bool
    /// The "Unavailable" badge of a secure item whose Keychain key cannot be read, nil otherwise.
    public let unavailableBadge: String?
    /// The "⌘1" to "⌘9" badge: only the first nine visible rows have one.
    public let shortcutBadge: String?
    public let accessibilityLabel: String

    public init(row: ItemRow, position: Int, now: Date) {
        id = row.id
        kind = row.kind
        // A secure row always shows the mask here: when its key is gone `primaryLine` holds the unavailable label, which
        // the badge below says instead.
        primaryText = row.isSecure ? SecureClip.mask : row.primaryLine
        isSecure = row.isSecure
        sourceBundleId = row.sourceBundleId
        unavailableBadge = row.isSecure && row.isUnavailable ? LibraryText.string("ui.library.secureUnavailable") : nil
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
    public enum Section: Sendable, Hashable { case top, types, tags, apps }

    public let filter: LibraryFilter
    public let section: Section
    public let title: String
    public let count: Int
    /// A tag with no items is dimmed, not hidden (FR-003-12).
    public let isDimmed: Bool

    public var id: LibraryFilter { filter }

    /// The sidebar in order: All, Pinned, Notes, Shortcuts (each dimmed at zero); the types that have items, Videos (when any video file exists) after Screenshots' place; tags alphabetically; the top apps by count. The
    /// query layer already orders tags and caps apps (`SidebarCounts`), so this only labels them.
    public static func entries(from counts: SidebarCounts, typeOrder: TypeOrder = .default) -> [SidebarEntry] {
        var entries = [
            SidebarEntry(filter: .all, section: .top, title: LibraryText.string("ui.library.sidebarAll"), count: counts.all, isDimmed: counts.all == 0),
            SidebarEntry(filter: .pinned, section: .top, title: LibraryText.string("ui.library.sidebarPinned"), count: counts.pinned, isDimmed: counts.pinned == 0),
            SidebarEntry(filter: .hasNote, section: .top, title: LibraryText.string("ui.library.sidebarNotes"), count: counts.notes, isDimmed: counts.notes == 0),
            SidebarEntry(filter: .hasShortcut, section: .top, title: LibraryText.string("ui.library.sidebarShortcuts"), count: counts.shortcuts, isDimmed: counts.shortcuts == 0),
        ]
        let shownKinds = typeOrder.shown(counts: counts.kinds)
        let videosSlot = videosPosition(among: shownKinds, typeOrder: typeOrder)
        let videos = SidebarEntry(filter: .videos, section: .types, title: LibraryText.string("ui.library.sidebarVideos"), count: counts.videos, isDimmed: false)
        for (index, kind) in shownKinds.enumerated() {
            if index == videosSlot, counts.videos > 0 { entries.append(videos) }
            let count = counts.kinds[kind] ?? 0
            entries.append(SidebarEntry(filter: .kind(kind), section: .types, title: LibraryText.typeTitle(kind), count: count, isDimmed: false))
        }
        if videosSlot == shownKinds.count, counts.videos > 0 { entries.append(videos) }
        for tag in counts.tags {
            entries.append(SidebarEntry(filter: .tag(tag.id), section: .tags, title: tag.name, count: tag.count, isDimmed: tag.count == 0))
        }
        for app in counts.apps {
            entries.append(SidebarEntry(filter: .sourceApp(app.identity), section: .apps, title: appTitle(app), count: app.count, isDimmed: false))
        }
        return entries
    }

    /// Where the Videos row goes among the shown type rows: right after Screenshots' place in the `library.types` list.
    /// Videos are not a kind (they are files, so the list cannot switch them off) and the row follows only its own
    /// count (FR-003-12): Screenshots having no items, or being switched off, never hides it. With Screenshots listed
    /// the row sits after the last shown type at or before Screenshots' place; with it switched off, last.
    private static func videosPosition(among shown: [ItemKind], typeOrder: TypeOrder) -> Int {
        guard let screenshotPlace = typeOrder.kinds.firstIndex(of: .screenshot) else { return shown.count }
        return shown.prefix { (typeOrder.kinds.firstIndex(of: $0) ?? 0) <= screenshotPlace }.count
    }

    private static func appTitle(_ app: SidebarCounts.AppCount) -> String {
        switch app.identity {
        case .anotherDevice: LibraryText.string("ui.library.appAnotherDevice")
        case .unknown: LibraryText.string("ui.library.appUnknown")
        case .bundle(let id): app.name ?? id
        }
    }
}

/// The footer (FR-003-11, FR-003-18): the core keys in one fixed order (the first is the leading action), the count, and
/// the copy-only notice.
public struct LibraryFooter: Equatable {
    public struct Hint: Equatable {
        public let key: String
        public let label: String
    }

    public let hints: [Hint]
    /// `hints` without the lowest-priority one (the third: Plain Text, or Copy while pasting is off). The footer draws this
    /// when the full row would not fit on one line at the compact width (FR-003-18, hill-climb r6).
    public var essentialHints: [Hint] { hints.count == 4 ? hints.enumerated().filter { $0.offset != 2 }.map(\.element) : hints }
    public let countText: String
    /// "Press ⌘V to paste" when Accessibility is off; "Return starts a paste queue" while several rows are selected; the
    /// queue's remaining count and "Esc cancels" while one waits (FR-003-25).
    public let notice: String?
    /// The "Enable" button's label while Accessibility is off (FR-008-14); nil when pasting works.
    public let enableLabel: String?
    /// The active sort's name, shown beside the count (FR-004-12). Empty, like `countText`, while there are no rows to count.
    public let sortName: String

    public init(
        totalCount: Int, selectionCount: Int, isAccessibilityTrusted: Bool, sort: LibrarySort,
        queueRemaining: Int = 0, previewShowing: Bool = false, previewReplacesList: Bool = false
    ) {
        // With no rows (an empty history, a search with no results) there is nothing to sort or count, so neither is shown
        // ("Recent 0 items" under a no-results message says nothing true, FR-003-18).
        sortName = totalCount > 0 || selectionCount >= 2 ? LibraryText.sortName(sort) : String()
        enableLabel = isAccessibilityTrusted ? nil : LibraryText.string("ui.library.footerEnable")
        let multi = selectionCount >= 2
        if multi {
            hints = [
                Hint(key: LibraryText.string("ui.library.keyReturn"), label: LibraryText.string("ui.library.hintQueue")),
                Hint(key: LibraryText.string("ui.library.keyEsc"), label: LibraryText.string("ui.library.hintClearSelection")),
            ]
            countText = LibraryText.selectedCount(selectionCount)
            notice = LibraryText.string("ui.library.footerMultiDisabled")
            return
        }
        // The same four hints in the same places whenever there are rows (FR-003-18); only the third one swaps with
        // Accessibility. With nothing in the list the hints that have nothing to act on are left out, Esc stays.
        let close = Hint(key: LibraryText.string("ui.library.keyEsc"), label: LibraryText.string("ui.library.hintClose"))
        if totalCount > 0 {
            let paste = Hint(key: LibraryText.string("ui.library.keyReturn"), label: LibraryText.string("ui.library.hintPaste"))
            // While the preview shows, Space closes it, so the hint says so: "Back to List" when the preview has taken the
            // list's place (Compact), "Close Preview" beside it (FR-003-18, hill-climb r5 and r6).
            let previewLabel = previewReplacesList
                ? "ui.library.hintBackToList" : previewShowing ? "ui.library.hintClosePreview" : "ui.library.hintPreview"
            let preview = Hint(key: LibraryText.string("ui.library.keySpace"), label: LibraryText.string(previewLabel))
            let secondary = isAccessibilityTrusted
                ? Hint(key: LibraryText.string("ui.library.keyOptionReturn"), label: LibraryText.string("ui.library.hintPlain"))
                : Hint(key: LibraryText.string("ui.library.keyCommandC"), label: LibraryText.string("ui.library.hintCopy"))
            hints = [paste, preview, secondary, close]
        } else {
            hints = [close]
        }
        countText = totalCount > 0 ? LibraryText.itemCount(totalCount) : String()
        // A waiting paste queue says so, and that Esc drops it (FR-003-25); it outranks the copy-only reminder, which the
        // enable button still carries.
        if queueRemaining > 0 {
            notice = LibraryText.format("ui.library.footerQueue", queueRemaining)
        } else {
            notice = isAccessibilityTrusted ? nil : LibraryText.string("ui.library.footerCopyOnly")
        }
    }
}
