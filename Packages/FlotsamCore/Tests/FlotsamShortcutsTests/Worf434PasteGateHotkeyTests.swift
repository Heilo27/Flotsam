import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamShortcuts

// TASK-434 (Worf, blind): the item hotkey (FR-005-05) through the REAL PasteService and PasteExpansion, over fakes on
// the system ports. Contract: FR-005-05, FR-003-15, FR-003-17, OC-8119.

private final class W434HotkeyProbe: PermissionProbe, @unchecked Sendable {
    private let accessibility: Bool
    init(accessibility: Bool) { self.accessibility = accessibility }
    func isGranted(_ kind: PermissionKind) -> Bool { kind == .accessibility ? accessibility : false }
    func request(_ kind: PermissionKind) {}
    func openSystemSettings(_ kind: PermissionKind) {}
}

private final class W434HotkeyStore: PasteItemStore, @unchecked Sendable {
    private let lock = NSLock()
    private let content: ItemContent
    private var _recorded: [UUID] = []
    init(text: String) {
        content = ItemContent(
            kind: .text, plainText: text,
            representations: [PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))], members: [])
    }
    var recorded: [UUID] { lock.withLock { _recorded } }
    func content(of itemId: UUID) async -> FlotsamResult<ItemContent> { .success(content) }
    func recordPaste(of itemId: UUID) async -> FlotsamResult<Void> { lock.withLock { _recorded.append(itemId) }; return .success(()) }
    func delete(ids: [UUID]) async -> FlotsamResult<[UUID]> { .success(ids) }
}

private struct W434HotkeyFiles: FileSystemPort {
    private func unused() -> FlotsamResult<Void> { .failure(FlotsamError(.sysInt001, "unused")) }
    func fileExists(at url: URL) -> Bool { false }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func removeItem(at url: URL) -> FlotsamResult<Void> { unused() }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { .failure(FlotsamError(.sysInt001, "unused")) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { nil }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func readFile(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused")) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused")) }
    func fileInfo(at url: URL) -> FileInfo? { nil }
    func availableCapacity(at url: URL) -> Int64? { nil }
}

private struct W434NoRichText: RichTextCodec {
    func decode(_ representations: [PasteboardRepresentation]) -> AttributedString? { nil }
    func encode(_ text: AttributedString) -> FlotsamResult<[PasteboardRepresentation]> {
        .failure(FlotsamError(.trgOs002, "no codec in tests"))
    }
}

@MainActor
private final class W434HotkeyBoard: PasteboardPort {
    private(set) var changeCount = 0
    private(set) var writes: [[PasteboardRepresentation]] = []
    private var items: [PasteboardRepresentation]
    init(plainText: String) { items = [PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data(plainText.utf8))] }
    func currentTypeIdentifiers() -> [String] { items.map(\.uti) }
    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        .success(PasteboardSnapshot(changeCount: changeCount, typeIdentifiers: items.map(\.uti), representations: items))
    }
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        items = representations
        writes.append(representations)
        changeCount += 1
        return .success(changeCount)
    }
    var text: String? {
        items.first { $0.uti == "public.utf8-plain-text" }.flatMap { String(data: $0.data, encoding: .utf8) }
    }
}

@MainActor
private struct W434HotkeyFrontmost: FrontmostAppProvider {
    let app: FrontmostApp
    func frontmost() -> FrontmostApp? { app }
}

@MainActor
private final class W434HotkeyKeys: KeyEventPoster {
    private(set) var targets: [FrontmostApp] = []
    func postPaste(to target: FrontmostApp) -> Bool { targets.append(target); return true }
}

private struct W434HotkeyClock: WallClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(for duration: Duration) async {}
}

@MainActor
private final class W434Reports {
    var errors: [FlotsamError] = []
}

private let w434App = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)
private let w434Item = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

@MainActor
private struct W434HotkeyRig {
    let board = W434HotkeyBoard(plainText: "previous clipboard")
    let keys = W434HotkeyKeys()
    let store = W434HotkeyStore(text: "hotkey item")
    let reports = W434Reports()
    let action: ItemHotkeyAction

    init(accessibility: Bool) {
        let clock = W434HotkeyClock()
        let ledger = OwnWriteLedger()
        let frontmost = W434HotkeyFrontmost(app: w434App)
        let service = PasteService(
            store: store, pasteboard: board, files: W434HotkeyFiles(), frontmost: frontmost,
            accessibility: W434HotkeyProbe(accessibility: accessibility), keys: keys, clock: clock, ownWrites: ledger)
        let expansion = PasteExpansion(
            pasteboard: board, files: W434HotkeyFiles(), codec: W434NoRichText(),
            preserver: ClipboardPreserver(pasteboard: board, ownWrites: ledger, clock: clock),
            ownWrites: ledger, clock: clock, calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"))
        let reports = reports
        action = ItemHotkeyAction(
            paster: service, expansion: expansion, frontmost: frontmost, report: { reports.errors.append($0) })
    }
}

@MainActor
@Suite("TASK-434 Item hotkey through PasteGate")
struct Worf434PasteGateHotkeyTests {
    /// FR-005-05 / FR-003-17 / OC-8119. given Accessibility untrusted, when the item's hotkey fires over TextEdit, then
    /// no ⌘V is posted, the item (not the previous clipboard) is left on the pasteboard for ⌘V, the paste is recorded,
    /// and exactly one SET-PRM-001 naming the item is reported. Red if `pasteExpanded` skips the gate, if the action
    /// swallows `.copiedAccessibilityDenied`, or if it restores the previous clipboard over the item.
    @Test("OC-8119 untrusted: hotkey lands on copy-only with SET-PRM-001 and the item on the clipboard")
    func untrusted() async {
        let rig = W434HotkeyRig(accessibility: false)

        await rig.action.run(itemId: w434Item)

        #expect(rig.keys.targets.isEmpty)
        #expect(rig.board.text == "hotkey item")
        #expect(rig.board.writes.count == 1)
        #expect(rig.store.recorded == [w434Item])
        #expect(rig.reports.errors.count == 1)
        #expect(rig.reports.errors.first?.code == .setPrm001)
        #expect(rig.reports.errors.first?.context[.itemId] == .id(w434Item))
    }

    /// FR-005-05 / FR-005-16 inverse. given Accessibility trusted, then one ⌘V goes to TextEdit, the item was written
    /// once, the previous clipboard is restored after, and nothing is reported. Red if the gate returns copy-only for a
    /// trusted probe, or the restore is lost.
    @Test("trusted: hotkey pastes into the frontmost app and restores the previous clipboard")
    func trusted() async {
        let rig = W434HotkeyRig(accessibility: true)

        await rig.action.run(itemId: w434Item)

        #expect(rig.keys.targets == [w434App])
        #expect(rig.board.writes.count == 2)
        #expect(rig.board.writes.first?.first { $0.uti == "public.utf8-plain-text" }
            .flatMap { String(data: $0.data, encoding: .utf8) } == "hotkey item")
        #expect(rig.board.text == "previous clipboard")
        #expect(rig.store.recorded == [w434Item])
        #expect(rig.reports.errors.isEmpty)
    }

    /// The error mapping seam. given each paste result, then only `.copiedAccessibilityDenied` becomes SET-PRM-001 with
    /// the item id, a failure passes through unchanged, and `.pasted` / `.copied` are silent. Red if any branch is
    /// remapped.
    @Test("error(for:) maps only the denied outcome to SET-PRM-001 and passes other failures through")
    func errorMapping() {
        let failure = FlotsamError(.libOs001, "target changed")
        #expect(ItemHotkeyAction.error(for: .success(.pasted), itemId: w434Item) == nil)
        #expect(ItemHotkeyAction.error(for: .success(.copied), itemId: w434Item) == nil)
        let denied = ItemHotkeyAction.error(for: .success(.copiedAccessibilityDenied), itemId: w434Item)
        #expect(denied?.code == .setPrm001)
        #expect(denied?.context[.itemId] == .id(w434Item))
        #expect(ItemHotkeyAction.error(for: .failure(failure), itemId: w434Item)?.code == .libOs001)
    }
}
