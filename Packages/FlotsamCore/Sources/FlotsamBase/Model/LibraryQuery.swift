import Foundation

/// Which source-app row of the sidebar is selected (FRD-004 FR-004-10). A bundle identifier, or one of the two buckets
/// for items that have no bundle identifier.
public enum SourceAppIdentity: Sendable, Equatable, Hashable {
    case bundle(String)
    /// Universal Clipboard (FRD-001 FR-001-14): no bundle identifier, name `SourceApp.anotherDeviceName`.
    case anotherDevice
    /// Source could not be resolved (FRD-001 FR-001-13).
    case unknown
}

extension SourceApp {
    /// The stored source name of a Universal Clipboard copy (FRD-001 FR-001-14). It is the only thing that tells the
    /// "Another device" bucket apart from "Unknown", because neither has a bundle identifier, so the capture side
    /// (writes it) and the query layer (reads it) share this one constant.
    public static let anotherDeviceName = "Another device"
}

/// The single sidebar filter (FRD-004 FR-004-10). Exactly one applies; the free-text query is independent of it.
public enum LibraryFilter: Sendable, Equatable, Hashable {
    case all
    case pinned
    case kind(ItemKind)
    case tag(Int64)
    case sourceApp(SourceAppIdentity)
}

/// The sort model (FRD-004 FR-004-12). Every sort ends in the same stable tie-break, so repeated loads agree.
public enum LibrarySort: String, Sendable, Equatable, CaseIterable {
    case recent, oldest, mostUsed, alphabetical

    /// ⌘S cycles in declaration order: Recent, Oldest, Most Used, A to Z, then back to Recent (FR-004-12).
    public var next: LibrarySort {
        let all = Self.allCases
        return all[(all.firstIndex(of: self).map { $0 + 1 } ?? 0) % all.count]
    }
}

/// One request to the query layer (FR-007-18): filter, search text and sort, for one page.
public struct LibraryQuery: Sendable, Equatable {
    /// Rows per page (FR-007-18).
    public static let pageSize = 200

    public var filter: LibraryFilter
    /// Raw search text; the query layer splits and normalises it (FRD-003 FR-003-09).
    public var text: String
    public var sort: LibrarySort
    /// Zero-based page number.
    public var page: Int

    public init(filter: LibraryFilter = .all, text: String = "", sort: LibrarySort = .recent, page: Int = 0) {
        self.filter = filter
        self.text = text
        self.sort = sort
        self.page = max(0, page)
    }
}

/// What a Library row or Shelf card needs, already joined, so rendering never issues a second query per row.
public struct ItemRow: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: ItemKind
    public let lastCopiedAt: Date
    public let pasteCount: Int
    /// FRD-003 FR-003-07 primary line as plain text. It is also the key of the alphabetical sort (FR-004-12).
    public let primaryLine: String
    public let sourceName: String?
    /// Tag names, alphabetical.
    public let tagNames: [String]
    public let isPinned: Bool
    public let hasTrigger: Bool
    public let hasShortcut: Bool
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let memberCount: Int
    public let byteSize: Int64

    public init(
        id: UUID, kind: ItemKind, lastCopiedAt: Date, pasteCount: Int, primaryLine: String, sourceName: String?,
        tagNames: [String], isPinned: Bool, hasTrigger: Bool, hasShortcut: Bool, pixelWidth: Int?, pixelHeight: Int?,
        memberCount: Int, byteSize: Int64
    ) {
        self.id = id
        self.kind = kind
        self.lastCopiedAt = lastCopiedAt
        self.pasteCount = pasteCount
        self.primaryLine = primaryLine
        self.sourceName = sourceName
        self.tagNames = tagNames
        self.isPinned = isPinned
        self.hasTrigger = hasTrigger
        self.hasShortcut = hasShortcut
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.memberCount = memberCount
        self.byteSize = byteSize
    }
}

/// One page of results plus the size of the whole result set (the "{n} items" footer, FRD-004 FR-004-13).
public struct ItemPage: Sendable, Equatable {
    public let rows: [ItemRow]
    public let totalCount: Int
    public let page: Int

    public var hasMore: Bool { (page + 1) * LibraryQuery.pageSize < totalCount }

    public init(rows: [ItemRow], totalCount: Int, page: Int) {
        self.rows = rows
        self.totalCount = totalCount
        self.page = page
    }
}

/// Sidebar rows with their counts (FRD-003 FR-003-12). Counts come from the same filter semantics as `ItemPage`.
public struct SidebarCounts: Sendable, Equatable {
    public struct TagCount: Sendable, Equatable {
        public let id: Int64
        public let name: String
        public let color: String?
        public let count: Int

        public init(id: Int64, name: String, color: String?, count: Int) {
            self.id = id
            self.name = name
            self.color = color
            self.count = count
        }
    }
    public struct AppCount: Sendable, Equatable {
        public let identity: SourceAppIdentity
        public let name: String?
        public let count: Int

        public init(identity: SourceAppIdentity, name: String?, count: Int) {
            self.identity = identity
            self.name = name
            self.count = count
        }
    }

    public let all: Int
    public let pinned: Int
    /// Only kinds with at least one item are present (empty types are hidden).
    public let kinds: [ItemKind: Int]
    /// Alphabetical.
    public let tags: [TagCount]
    /// Ordered by count, top 15.
    public let apps: [AppCount]

    public init(all: Int, pinned: Int, kinds: [ItemKind: Int], tags: [TagCount], apps: [AppCount]) {
        self.all = all
        self.pinned = pinned
        self.kinds = kinds
        self.tags = tags
        self.apps = apps
    }
}
