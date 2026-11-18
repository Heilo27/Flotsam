import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

/// A source that answers per filter: `.all` -> 5 rows "all N", `.pinned` -> 1 row "pinned", `.kind(.text)` -> 2 rows
/// "text N". The `.pinned` answer is slow, so a superseded `.pinned` load completes after the final `.all` one.
private final class FilterAwareSource: LibraryDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _filters: [LibraryFilter] = []
    var filters: [LibraryFilter] { lock.withLock { _filters } }
    let counts = SidebarCounts(
        all: 5, pinned: 1, kinds: [.text: 2, .link: 1],
        tags: [SidebarCounts.TagCount(id: 7, name: "Work", color: nil, count: 2)], apps: [])

    func items(matching query: LibraryQuery) async -> FlotsamResult<ItemPage> {
        lock.withLock { _filters.append(query.filter) }
        let rows: [ItemRow]
        switch query.filter {
        case .all: rows = (0..<5).map { makeRow($0, primary: "all \($0)") }
        case .pinned:
            try? await Task.sleep(for: .milliseconds(150))
            rows = [makeRow(50, primary: "pinned", pinned: true)]
        case .kind(.text): rows = (60..<62).map { makeRow($0, primary: "text \($0)") }
        default: rows = []
        }
        return .success(ItemPage(rows: rows, totalCount: rows.count, page: 0))
    }
    func sidebarCounts() async -> FlotsamResult<SidebarCounts> { .success(counts) }
    func content(of itemId: UUID) async -> FlotsamResult<ItemContent> {
        .success(ItemContent(kind: .text, plainText: "x", representations: [], members: []))
    }
    func thumbnail(itemId: UUID, size: ThumbnailSize) async -> Data? { nil }
    func releaseMemory() async {}
}

@MainActor
@Suite struct SidebarFilterWorfTests {
    private func model(_ source: FilterAwareSource) -> LibraryViewModel {
        LibraryViewModel(
            source: source, paster: FakePaster(), host: FakeHost(), preferences: FakePreferences(),
            effects: LibraryEffects(
                report: { _ in }, reveal: { _ in }, openSettings: {}, external: { _, _ in },
                isAccessibilityTrusted: { true }))
    }

    private func key(_ input: LibraryKeyInput, _ modifiers: ChordModifiers = []) -> LibraryKeyStroke {
        LibraryKeyStroke(input, modifiers)
    }

    /// OC-7025-sidebar: given a slow superseded .pinned load, when option-arrows step down then back up to All, then
    /// the rows the user reads are the five "all N" rows, not the pinned/text rows a superseded load returned.
    /// Mutation: skip the final reload, or let a superseded load apply -> red.
    @Test func finalFilterAllShowsTheAllRowsAfterSteppingAwayAndBack() async {
        let source = FilterAwareSource()
        let m = model(source)
        await m.open(target: FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242))
        m.handle(key(.down, .option))
        m.handle(key(.down, .option))
        m.handle(key(.up, .option)); m.handle(key(.up, .option)); m.handle(key(.up, .option))
        await m.settled()
        // Let the slow superseded .pinned load finish, so a missing staleness guard would show.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(m.filter == .all)
        #expect(m.visibleRows.map(\.primaryLine) == ["all 0", "all 1", "all 2", "all 3", "all 4"])
        #expect(m.totalCount == 5)
    }

    /// Given the filter steps to Pinned and stays, then the pinned row is what is displayed (a wrong final filter
    /// must show different rows from All).
    @Test func finalFilterPinnedShowsThePinnedRow() async {
        let source = FilterAwareSource()
        let m = model(source)
        await m.open(target: FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242))
        m.handle(key(.down, .option))
        await m.settled()
        #expect(m.filter == .pinned)
        #expect(m.visibleRows.map(\.primaryLine) == ["pinned"])
        #expect(m.totalCount == 1)
    }

    /// Boundary: option-up from All stays on All and issues no extra load (count delta 0).
    @Test func optionUpFromAllStaysAndDoesNotReload() async {
        let source = FilterAwareSource()
        let m = model(source)
        await m.open(target: FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242))
        let before = source.filters.count
        m.handle(key(.up, .option))
        await m.settled()
        #expect(m.filter == .all)
        #expect(source.filters.count == before)
        #expect(m.visibleRows.count == 5)
    }
}
