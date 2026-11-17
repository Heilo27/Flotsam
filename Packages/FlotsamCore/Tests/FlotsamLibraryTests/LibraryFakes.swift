import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
@testable import FlotsamLibrary

func makeRow(
    _ n: Int = 0, kind: ItemKind = .text, primary: String? = nil, source: String? = "Notes", tags: [String] = [],
    pinned: Bool = false, copiedAt: Date = Date(timeIntervalSince1970: 1_000_000)
) -> ItemRow {
    ItemRow(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)) ?? UUID(), kind: kind,
        lastCopiedAt: copiedAt, pasteCount: 0, primaryLine: primary ?? "item \(n)", sourceName: source, tagNames: tags,
        isPinned: pinned, hasTrigger: false, hasShortcut: false, pixelWidth: nil, pixelHeight: nil, memberCount: 0,
        byteSize: 0)
}

/// A scripted storage: serves `rows` filtered by a substring of the search text, in pages of `LibraryQuery.pageSize`.
final class FakeSource: LibraryDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _queries: [LibraryQuery] = []
    private var _released = 0
    var rows: [ItemRow]
    var failItems: FlotsamError?
    var counts: SidebarCounts
    var content: ItemContent = ItemContent(kind: .text, plainText: "hello", representations: [], members: [])
    /// Delay per search text, to make an earlier query finish after a later one.
    var delays: [String: Duration] = [:]

    init(rows: [ItemRow] = [], counts: SidebarCounts? = nil) {
        self.rows = rows
        self.counts = counts ?? SidebarCounts(all: rows.count, pinned: 0, kinds: [.text: rows.count], tags: [], apps: [])
    }

    var queries: [LibraryQuery] { lock.withLock { _queries } }
    var releaseCount: Int { lock.withLock { _released } }

    func items(matching query: LibraryQuery) async -> FlotsamResult<ItemPage> {
        lock.withLock { _queries.append(query) }
        if let delay = delays[query.text] { try? await Task.sleep(for: delay) }
        if let failItems { return .failure(failItems) }
        let matching = rows.filter { query.text.isEmpty || $0.primaryLine.contains(query.text) }
        let start = query.page * LibraryQuery.pageSize
        let slice = start < matching.count ? Array(matching[start..<min(start + LibraryQuery.pageSize, matching.count)]) : []
        return .success(ItemPage(rows: slice, totalCount: matching.count, page: query.page))
    }

    func sidebarCounts() async -> FlotsamResult<SidebarCounts> { .success(counts) }
    func content(of itemId: UUID) async -> FlotsamResult<ItemContent> { .success(content) }
    func thumbnail(itemId: UUID, size: ThumbnailSize) async -> Data? { nil }
    func releaseMemory() async { lock.withLock { _released += 1 } }
}

@MainActor
final class FakePaster: PastePerforming {
    struct Call: Equatable { let itemId: UUID; let mode: PasteMode; let target: FrontmostApp? }
    var calls: [Call] = []
    var result: FlotsamResult<PasteOutcome> = .success(.pasted)

    func paste(itemId: UUID, mode: PasteMode, target: FrontmostApp?, host: any PasteHost) async -> FlotsamResult<PasteOutcome> {
        calls.append(Call(itemId: itemId, mode: mode, target: target))
        return result
    }
}

@MainActor
final class FakeHost: PasteHost {
    var isPanelVisible = true
    var hideCount = 0
    func hidePanel() { hideCount += 1; isPanelVisible = false }
}

final class FakePreferences: LibraryPreferences, @unchecked Sendable {
    private let lock = NSLock()
    private var _viewMode: LibraryViewMode = .list
    private var _size = PanelSize(width: 760, height: 480)
    var viewMode: LibraryViewMode {
        get { lock.withLock { _viewMode } }
        set { lock.withLock { _viewMode = newValue } }
    }
    var panelSize: PanelSize {
        get { lock.withLock { _size } }
        set { lock.withLock { _size = newValue } }
    }
    var sort: LibrarySort { .recent }
}

@MainActor
struct Harness {
    let source: FakeSource
    let paster = FakePaster()
    let host = FakeHost()
    let prefs = FakePreferences()
    let model: LibraryViewModel
    let reported = Reported()

    @MainActor final class Reported {
        var errors: [FlotsamError] = []
        var external: [(LibraryExternalCommand, [UUID])] = []
        var revealed: [[String]] = []
        var settingsOpened = 0
    }

    init(rows: [ItemRow], counts: SidebarCounts? = nil, accessibility: Bool = true) {
        source = FakeSource(rows: rows, counts: counts)
        let reported = reported
        model = LibraryViewModel(
            source: source, paster: paster, host: host, preferences: prefs,
            effects: LibraryEffects(
                report: { reported.errors.append($0) }, reveal: { reported.revealed.append($0) },
                openSettings: { reported.settingsOpened += 1 },
                external: { reported.external.append(($0, $1)) }, isAccessibilityTrusted: { accessibility }))
    }

    static func rows(_ count: Int) -> [ItemRow] { (0..<count).map { makeRow($0) } }
}
