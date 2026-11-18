import FlotsamBase
import Foundation
@testable import FlotsamShelf

/// The Nth card's id, as `makeShelfRow(n)` derives it.
func shelfID(_ n: Int) -> UUID { makeShelfRow(n).id }

/// An ordered record of calls across fakes, so a test can assert what happened before what.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []
    var entries: [String] { lock.withLock { _entries } }
    func add(_ entry: String) { lock.withLock { _entries.append(entry) } }
}

/// A scripted storage: serves `rows` (already in `lastCopiedAt` order) filtered by the query's filter, and applies pins
/// and deletes to them, so a reload after an action sees the change.
final class FakeShelfSource: ShelfDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _rows: [ItemRow]
    private var _queries: [LibraryQuery] = []
    private var _pinCalls: [(ids: [UUID], pinned: Bool)] = []
    private var _deleteCalls: [[UUID]] = []
    private var _failItems: FlotsamError?
    let log: CallLog

    init(rows: [ItemRow] = [], log: CallLog = CallLog()) {
        _rows = rows
        self.log = log
    }

    var rows: [ItemRow] {
        get { lock.withLock { _rows } }
        set { lock.withLock { _rows = newValue } }
    }
    var failItems: FlotsamError? {
        get { lock.withLock { _failItems } }
        set { lock.withLock { _failItems = newValue } }
    }
    var queries: [LibraryQuery] { lock.withLock { _queries } }
    var pinCalls: [(ids: [UUID], pinned: Bool)] { lock.withLock { _pinCalls } }
    var deleteCalls: [[UUID]] { lock.withLock { _deleteCalls } }

    func items(matching query: LibraryQuery) async -> FlotsamResult<ItemPage> {
        log.add("items")
        let (rows, failure) = lock.withLock { () -> ([ItemRow], FlotsamError?) in
            _queries.append(query)
            return (_rows, _failItems)
        }
        if let failure { return .failure(failure) }
        let matching = query.filter == .pinned ? rows.filter(\.isPinned) : rows
        let page = Array(matching.prefix(LibraryQuery.pageSize))
        return .success(ItemPage(rows: page, totalCount: matching.count, page: 0))
    }

    func setPinned(ids: [UUID], pinned: Bool) async -> FlotsamResult<Bool> {
        lock.withLock {
            _pinCalls.append((ids, pinned))
            _rows = _rows.map { ids.contains($0.id) ? Self.copy($0, pinned: pinned) : $0 }
        }
        return .success(pinned)
    }

    func delete(ids: [UUID]) async -> FlotsamResult<[UUID]> {
        lock.withLock {
            _deleteCalls.append(ids)
            _rows.removeAll { ids.contains($0.id) }
        }
        return .success(ids)
    }

    private static func copy(_ row: ItemRow, pinned: Bool) -> ItemRow {
        ItemRow(
            id: row.id, kind: row.kind, lastCopiedAt: row.lastCopiedAt, pasteCount: row.pasteCount,
            primaryLine: row.primaryLine, sourceName: row.sourceName, tagNames: row.tagNames, isPinned: pinned,
            hasTrigger: row.hasTrigger, hasShortcut: row.hasShortcut, pixelWidth: row.pixelWidth,
            pixelHeight: row.pixelHeight, memberCount: row.memberCount, byteSize: row.byteSize)
    }
}

@MainActor
final class FakeShelfHost: ShelfPasteHost {
    var isPanelVisible = true
    var hideCount = 0
    func hidePanel() { hideCount += 1; isPanelVisible = false }
}

/// Records every paste; like the real service it hides the panel on success.
@MainActor
final class FakeShelfPaster: ShelfPasting {
    struct Call: Equatable { let itemId: UUID; let mode: ShelfPasteMode; let target: FrontmostApp? }
    var calls: [Call] = []
    var result: FlotsamResult<ShelfPasteOutcome> = .success(.pasted)

    func paste(itemId: UUID, mode: ShelfPasteMode, target: FrontmostApp?, host: any ShelfPasteHost) async -> FlotsamResult<ShelfPasteOutcome> {
        calls.append(Call(itemId: itemId, mode: mode, target: target))
        if case .success = result { host.hidePanel() }
        return result
    }
}

struct FakeShelfDetails: ShelfCardDetails {
    var texts: [UUID: String] = [:]
    var paths: [UUID: [String]] = [:]
    func cardTexts(for ids: [UUID]) async -> [UUID: String] { texts.filter { ids.contains($0.key) } }
    func memberPaths(of ids: [UUID]) async -> [UUID: [String]] { paths.filter { ids.contains($0.key) } }
}

/// A Sendable stand-in for the disk: every path exists until `only` names the ones that do.
final class FakeFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var present: Set<String>?
    func only(_ paths: Set<String>) { lock.withLock { present = paths } }
    func exists(_ path: String) -> Bool { lock.withLock { present?.contains(path) ?? true } }
}

/// What the model's effects observed.
@MainActor
final class EffectsProbe {
    var reports: [FlotsamError] = []
    var confirmQuestions: [String] = []
    var confirmAnswer = true
    var captureCount = 0
    var onCapture: (@MainActor () -> Void)?
    let files = FakeFiles()

    func effects(log: CallLog? = nil) -> ShelfEffects {
        ShelfEffects(
            report: { [self] in reports.append($0) },
            captureNow: { [self] in
                log?.add("captureNow")
                captureCount += 1
                onCapture?()
            },
            confirmDelete: { [self] question in
                confirmQuestions.append(question)
                return confirmAnswer
            },
            fileExists: { [files] path in files.exists(path) },
            now: { Date(timeIntervalSince1970: 1_000_100) })
    }
}

let textEdit = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

@MainActor
struct ShelfRig {
    let source: FakeShelfSource
    let paster = FakeShelfPaster()
    let host = FakeShelfHost()
    let bus = ItemEventBus()
    let probe = EffectsProbe()
    let log: CallLog
    let model: ShelfModel

    init(rows: [ItemRow], details: any ShelfCardDetails = NoShelfCardDetails(), configure: (EffectsProbe) -> Void = { _ in }) {
        log = CallLog()
        source = FakeShelfSource(rows: rows, log: log)
        configure(probe)
        model = ShelfModel(
            source: source, paster: paster, host: host, events: bus, details: details, effects: probe.effects(log: log))
    }

    /// Opens a sticky Shelf over TextEdit.
    func openSticky() async { await model.open(target: textEdit, sticky: true) }
}
