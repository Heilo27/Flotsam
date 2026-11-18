import FlotsamBase
import FlotsamPaste
import FlotsamShelf
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamShortcuts

// FRD-005 8T contract tests, slice S3 (item hotkey paste and the Shelf toggle: FR-005-05, FR-005-07, FR-005-21). Written
// from the blind oracle contract (.claude/oracle/frd-005-contract.json), with literal expected values. A press goes
// chord -> registry -> the bound action -> the real ItemHotkeyAction / PasteService / PasteExpansion over fakes on the
// system ports (the registrar, the pasteboard, the ⌘V poster, the frontmost app, the permission probe, the clock).
// Analogues left as they are: Worf434PasteGateHotkeyTests (permission gate) and ToggleShelfHotkeyEndToEndTests
// (OC-W314-00x and OC-6002/6003: the Toggle Shelf tests that OC-5041/5042 sit next to; they are not tagged 5041/5042).
//
// UNTESTABLE-AT-PACKAGE, no fake test written:
//  - OC-5131 (hotkey to ⌘V posted, p95 <= 150 ms over 50 pastes, paste.back signpost): needs real wall time and the real
//    signpost; every clock here is the fake `WallClock`, which does not measure work. Missing seam: a timing harness over
//    the real Carbon hotkey and CGEvent post (App/OS half).
//  - OC-5132 (100 item hotkeys add <= 50 ms to launch): needs a real launch and real Carbon registrations; the registrar
//    here is a fake. Missing seam: a launch-time benchmark in the App target.
//  - Parts of other OCs that sit in the App/OS half: "no Flotsam window appears" (5027: the hotkey path has no panel or
//    host at all, which the signature of `pasteExpanded` shows, but a window is an AppKit fact), "the text/image/date
//    lands in TextEdit or Notes" (5027, 5029, 5031, 5033: here the observable is the pasteboard content and the ⌘V
//    posted to the target app), the SET-PRM-001 HUD pixels (5028: here the catalogue text of the reported error), which
//    windows count as "Library key" or "Settings key" (5032: the registry's suspend switch is asserted; the App calls it),
//    and "the keystroke reaches TextEdit" (5042: here the chord is not registered, so nothing consumes it).

private enum Chords {
    static let ctrlOpt1 = Chord(keyCode: 18, modifiers: [.control, .option])
    static let ctrlOpt3 = Chord(keyCode: 20, modifiers: [.control, .option])
    static let ctrlOpt4 = Chord(keyCode: 21, modifiers: [.control, .option])
    static let ctrlOpt5 = Chord(keyCode: 23, modifiers: [.control, .option])
    static let cmdShift9 = Chord(keyCode: 25, modifiers: [.command, .shift])
}

private let textEdit = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)
private let notes = FrontmostApp(bundleId: "com.apple.Notes", processId: 5151)
private let mail = FrontmostApp(bundleId: "com.apple.mail", processId: 6161)
private let itemA = UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000A")!

private let catalogueSETPRM001 = "Accessibility is off, so Flotsam can't paste for you. The item is on your clipboard; press ⌘V."
private let catalogueLIBDAT001 = "The original file or folder has moved or been deleted."

private func milliseconds(_ duration: Duration) -> Int {
    let parts = duration.components
    return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
}

/// Everything that touches the pasteboard, the clock or the ⌘V poster, in order, as literals.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}

private final class ItemProbe: PermissionProbe, @unchecked Sendable {
    private let accessibility: Bool
    init(accessibility: Bool) { self.accessibility = accessibility }
    func isGranted(_ kind: PermissionKind) -> Bool { kind == .accessibility ? accessibility : false }
    func request(_ kind: PermissionKind) {}
    func openSystemSettings(_ kind: PermissionKind) {}
}

private final class ItemStore: PasteItemStore, @unchecked Sendable {
    private let lock = NSLock()
    private let item: ItemContent
    private var _recorded: [UUID] = []
    init(_ item: ItemContent) { self.item = item }
    var recorded: [UUID] { lock.withLock { _recorded } }
    func content(of itemId: UUID) async -> FlotsamResult<ItemContent> { .success(item) }
    func recordPaste(of itemId: UUID) async -> FlotsamResult<Void> { lock.withLock { _recorded.append(itemId) }; return .success(()) }
    func delete(ids: [UUID]) async -> FlotsamResult<[UUID]> { .success(ids) }
}

private struct ItemFiles: FileSystemPort {
    let existing: Set<String>
    private func unused() -> FlotsamResult<Void> { .failure(FlotsamError(.sysInt001, "unused")) }
    func fileExists(at url: URL) -> Bool { existing.contains(url.path) }
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

private struct ItemNoRichText: RichTextCodec {
    func decode(_ representations: [PasteboardRepresentation]) -> AttributedString? { nil }
    func encode(_ text: AttributedString) -> FlotsamResult<[PasteboardRepresentation]> {
        .failure(FlotsamError(.trgOs002, "no codec in tests"))
    }
}

@MainActor
private final class ItemBoard: PasteboardPort {
    private let log: EventLog
    private(set) var changeCount = 0
    private(set) var writes: [[PasteboardRepresentation]] = []
    private var items: [PasteboardRepresentation]
    init(plainText: String, log: EventLog) {
        items = [PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data(plainText.utf8))]
        self.log = log
    }
    func currentTypeIdentifiers() -> [String] { items.map(\.uti) }
    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        .success(PasteboardSnapshot(changeCount: changeCount, typeIdentifiers: items.map(\.uti), representations: items))
    }
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        items = representations
        writes.append(representations)
        changeCount += 1
        log.append("write")
        return .success(changeCount)
    }
    var text: String? {
        items.first { $0.uti == "public.utf8-plain-text" }.flatMap { String(data: $0.data, encoding: .utf8) }
    }
    func data(ofType uti: String) -> Data? { items.first { $0.uti == uti }?.data }
}

/// The frontmost app, switchable from the (off-main) clock hook, hence the lock instead of main-actor state.
private final class FrontmostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FrontmostApp
    init(_ value: FrontmostApp) { self.value = value }
    var app: FrontmostApp {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
private final class ItemFrontmost: FrontmostAppProvider {
    let box: FrontmostBox
    init(_ box: FrontmostBox) { self.box = box }
    func frontmost() -> FrontmostApp? { box.app }
}

@MainActor
private final class ItemKeys: KeyEventPoster {
    private let log: EventLog
    private(set) var targets: [FrontmostApp] = []
    init(log: EventLog) { self.log = log }
    func postPaste(to target: FrontmostApp) -> Bool { targets.append(target); log.append("post"); return true }
}

private final class ItemClock: WallClock, @unchecked Sendable {
    private let log: EventLog
    private let onSleep: (@Sendable () -> Void)?
    init(log: EventLog, onSleep: (@Sendable () -> Void)? = nil) { self.log = log; self.onSleep = onSleep }
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }  // 2027-01-15 08:00:00 UTC
    func sleep(for duration: Duration) async {
        log.append("sleep:\(milliseconds(duration))")
        onSleep?()
    }
}

@MainActor
private final class ItemReports {
    var errors: [FlotsamError] = []
    var pending: Task<Void, Never>?
}

private func textItem(_ text: String) -> ItemContent {
    ItemContent(kind: .text, plainText: text, representations: [], members: [])
}

@MainActor
private struct ItemHotkeyRig {
    let registry: ShortcutRegistry
    let registrar = FakeRegistrar()
    let board: ItemBoard
    let keys: ItemKeys
    let store: ItemStore
    let frontmost: ItemFrontmost
    let log = EventLog()
    let reports = ItemReports()

    init(
        content: ItemContent, chord: Chord, accessibility: Bool = true, frontmost app: FrontmostApp = textEdit,
        existingFiles: Set<String> = [], switchFrontmostDuringSettle other: FrontmostApp? = nil
    ) {
        let log = log
        board = ItemBoard(plainText: "prev-clip", log: log)
        keys = ItemKeys(log: log)
        store = ItemStore(content)
        let box = FrontmostBox(app)
        let front = ItemFrontmost(box)
        frontmost = front
        let clock = ItemClock(log: log) {
            if let other { box.app = other }
        }
        let board = board
        let ledger = OwnWriteLedger()
        let files = ItemFiles(existing: existingFiles)
        let service = PasteService(
            store: store, pasteboard: board, files: files, frontmost: front,
            accessibility: ItemProbe(accessibility: accessibility), keys: keys, clock: clock, ownWrites: ledger)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expansion = PasteExpansion(
            pasteboard: board, files: files, codec: ItemNoRichText(),
            preserver: ClipboardPreserver(pasteboard: board, ownWrites: ledger, clock: clock),
            ownWrites: ledger, clock: clock, calendar: utc, locale: Locale(identifier: "en_US"))
        let reports = reports
        let action = ItemHotkeyAction(
            paster: service, expansion: expansion, frontmost: front, report: { reports.errors.append($0) })
        registry = ShortcutRegistry(registrar: registrar, systemHotkeys: FakeSystemHotkeys(chords: []))
        registry.setAction(.item(itemA)) { reports.pending = Task { await action.run(itemId: itemA) } }
        _ = registry.bind(.item(itemA), to: chord)
    }

    /// The user presses `chord`; the paste sequence it starts is awaited.
    func press(_ chord: Chord) async {
        registrar.press(chord)
        await reports.pending?.value
        reports.pending = nil
    }
}

@MainActor @Suite struct FRD005ContractTestsItemHotkey {
    // MARK: OC-5027 .. OC-5033 (item hotkey paste)

    @Test("OC-5027 ⌃⌥1 pastes 'hk-text-123' into TextEdit with no panel, restores 'prev-clip' within 600 ms, and counts one paste")
    func oc5027HotkeyPastesAndRestoresTheClipboard() async {
        // given item A (text 'hk-text-123') on ⌃⌥1, TextEdit frontmost, clipboard 'prev-clip', Accessibility granted
        let rig = ItemHotkeyRig(content: textItem("hk-text-123"), chord: Chords.ctrlOpt1)
        // when the user presses ⌃⌥1
        await rig.press(Chords.ctrlOpt1)
        // then the item was written, ⌘V went to TextEdit once, the previous clipboard came back 300 ms after ⌘V (within 600),
        // the paste was counted once for A, and nothing was reported
        let itemWrite = rig.board.writes.first?.first { $0.uti == "public.utf8-plain-text" }
        #expect(itemWrite.flatMap { String(data: $0.data, encoding: .utf8) } == "hk-text-123")
        #expect(rig.keys.targets == [FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)])
        #expect(rig.log.all == ["write", "sleep:40", "post", "sleep:300", "write"])
        #expect(rig.board.writes.count == 2)
        #expect(rig.board.text == "prev-clip")
        #expect(rig.store.recorded == [itemA])
        #expect(rig.reports.errors.isEmpty)
    }

    @Test("OC-5028 without Accessibility ⌃⌥1 inserts nothing, leaves 'hk-text-123' on the clipboard, and reports the SET-PRM-001 text")
    func oc5028NoAccessibilityLeavesTheItemOnTheClipboard() async {
        // given the same item and hotkey with Accessibility not granted, 'prev-clip' on the clipboard
        let rig = ItemHotkeyRig(content: textItem("hk-text-123"), chord: Chords.ctrlOpt1, accessibility: false)
        // when the user presses ⌃⌥1 in TextEdit
        await rig.press(Chords.ctrlOpt1)
        // then no ⌘V was posted, the clipboard holds the item (not restored), and one HUD error reads the catalogue text
        #expect(rig.keys.targets.isEmpty)
        #expect(rig.board.text == "hk-text-123")
        #expect(rig.board.writes.count == 1)
        #expect(rig.reports.errors.count == 1)
        #expect(rig.reports.errors.first?.code == .setPrm001)
        #expect(rig.reports.errors.first.map { FlotsamStrings.message(for: $0) } == catalogueSETPRM001)
    }

    @Test("OC-5029 ⌃⌥3 on an image item writes the image bytes to the pasteboard and posts ⌘V to the rich TextEdit document")
    func oc5029ImageItemIsPasted() async {
        // given an image item (4 PNG signature bytes) on ⌃⌥3, TextEdit frontmost
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let image = ItemContent(
            kind: .image, plainText: nil, representations: [PasteboardRepresentation(uti: "public.png", data: png)], members: [])
        let rig = ItemHotkeyRig(content: image, chord: Chords.ctrlOpt3)
        // when the user presses ⌃⌥3
        await rig.press(Chords.ctrlOpt3)
        // then the first write carried exactly those bytes as public.png, ⌘V went to TextEdit, nothing was reported
        let written = rig.board.writes.first?.first { $0.uti == "public.png" }
        #expect(written?.data == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(rig.keys.targets == [FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)])
        #expect(rig.store.recorded == [itemA])
        #expect(rig.reports.errors.isEmpty)
    }

    @Test("OC-5030 ⌃⌥4 on a file item whose file is gone inserts nothing, shows LIB-DAT-001, and leaves 'prev-clip' untouched")
    func oc5030DeletedFileLeavesTheClipboardAlone() async {
        // given a file item on ⌃⌥4 whose only file is not on disk, clipboard 'prev-clip'
        let member = ItemMember(path: "/Volumes/Gone/report.txt", bookmark: nil, isDirectory: false)
        let file = ItemContent(kind: .file, plainText: nil, representations: [], members: [member])
        let rig = ItemHotkeyRig(content: file, chord: Chords.ctrlOpt4)
        // when the user presses ⌃⌥4 in TextEdit
        await rig.press(Chords.ctrlOpt4)
        // then nothing was written or posted, the clipboard is still 'prev-clip', and one HUD error reads the catalogue text
        #expect(rig.board.writes.isEmpty)
        #expect(rig.keys.targets.isEmpty)
        #expect(rig.board.text == "prev-clip")
        #expect(rig.reports.errors.count == 1)
        #expect(rig.reports.errors.first?.code == .libDat001)
        #expect(rig.reports.errors.first.map { FlotsamStrings.message(for: $0) } == catalogueLIBDAT001)
    }

    @Test("OC-5030 control: the same file item with its file on disk pastes the file URL and reports nothing")
    func oc5030ControlPresentFilePastes() async {
        // given the same item, but the file exists
        let member = ItemMember(path: "/Volumes/Present/report.txt", bookmark: nil, isDirectory: false)
        let file = ItemContent(kind: .file, plainText: nil, representations: [], members: [member])
        let rig = ItemHotkeyRig(content: file, chord: Chords.ctrlOpt4, existingFiles: ["/Volumes/Present/report.txt"])
        // when the user presses ⌃⌥4
        await rig.press(Chords.ctrlOpt4)
        // then the file URL was written first, ⌘V posted once, nothing reported
        let url = rig.board.writes.first?.first { $0.uti == "public.file-url" }
        #expect(url.flatMap { String(data: $0.data, encoding: .utf8) } == "file:///Volumes/Present/report.txt")
        #expect(rig.keys.targets.count == 1)
        #expect(rig.reports.errors.isEmpty)
    }

    @Test("OC-5031 ⌃⌥5 on '{date:yyyy-MM-dd}' inserts the date 2027-01-15, not the literal variable")
    func oc5031DateVariableIsExpanded() async {
        // given a text item '{date:yyyy-MM-dd}' on ⌃⌥5 and a clock at 2027-01-15 08:00 UTC
        let rig = ItemHotkeyRig(content: textItem("{date:yyyy-MM-dd}"), chord: Chords.ctrlOpt5)
        // when the user presses ⌃⌥5
        await rig.press(Chords.ctrlOpt5)
        // then the pasteboard got '2027-01-15' on the paste write, and the literal text was never written
        let pasted = rig.board.writes.first?.first { $0.uti == "public.utf8-plain-text" }
        #expect(pasted.flatMap { String(data: $0.data, encoding: .utf8) } == "2027-01-15")
        let literalWrites = rig.board.writes.filter { write in
            write.contains { String(data: $0.data, encoding: .utf8) == "{date:yyyy-MM-dd}" }
        }
        #expect(literalWrites.isEmpty)
        #expect(rig.keys.targets.count == 1)
    }

    @Test("OC-5032 with the Library panel or the Settings window key, ⌃⌥1 pastes nothing; it works again once they are not key")
    func oc5032ItemHotkeysAreOffWhileAFlotsamWindowIsKey() {
        // given item A on ⌃⌥1 and Open Library on ⌃⌘V
        let registrar = FakeRegistrar()
        let registry = ShortcutRegistry(registrar: registrar, systemHotkeys: FakeSystemHotkeys(chords: []))
        var pastes = 0
        var library = 0
        registry.setAction(.item(itemA)) { pastes += 1 }
        registry.setAction(.openLibrary) { library += 1 }
        #expect(registry.bind(.item(itemA), to: Chords.ctrlOpt1).isSuccess)
        #expect(registry.bind(.openLibrary, to: .ctrlCmdV).isSuccess)
        // when the Library panel becomes key and ⌃⌥1 is pressed, then it resigns and the Settings window becomes key and ⌃⌥1 is pressed
        registry.setItemHotkeysSuspended(true)
        registrar.press(Chords.ctrlOpt1)
        let liveWhileLibraryKey = registrar.liveChords
        registry.setItemHotkeysSuspended(false)
        registry.setItemHotkeysSuspended(true)
        registrar.press(Chords.ctrlOpt1)
        // then A was not pasted either time, the global Open Library chord stayed live, and the binding was kept
        #expect(pastes == 0)
        #expect(liveWhileLibraryKey == [Chord(keyCode: 9, modifiers: [.control, .command])])
        #expect(registry.chord(for: .item(itemA)) == Chord(keyCode: 18, modifiers: [.control, .option]))
        // when no Flotsam window is key any more and ⌃⌥1 is pressed
        registry.setItemHotkeysSuspended(false)
        registrar.press(Chords.ctrlOpt1)
        // then it pastes A exactly once
        #expect(pastes == 1)
        #expect(registrar.live.count == 2)
    }

    @Test("OC-5033 with Notes frontmost at key-down, ⌃⌥1 posts ⌘V to Notes and to no other app")
    func oc5033PasteGoesToTheAppFrontmostAtKeyDown() async {
        // given item A on ⌃⌥1 and Notes frontmost
        let rig = ItemHotkeyRig(content: textItem("hk-text-123"), chord: Chords.ctrlOpt1, frontmost: notes)
        // when the user presses ⌃⌥1
        await rig.press(Chords.ctrlOpt1)
        // then ⌘V went to Notes (process 5151) once
        #expect(rig.keys.targets == [FrontmostApp(bundleId: "com.apple.Notes", processId: 5151)])
        #expect(rig.reports.errors.isEmpty)
    }

    @Test("OC-5033 negative: if another app takes focus after key-down, ⌘V is not posted to it; the item stays on the clipboard")
    func oc5033FocusMovingAfterKeyDownDoesNotRedirectThePaste() async {
        // given item A on ⌃⌥1, Notes frontmost at key-down, and Mail taking focus during the settle pause
        let rig = ItemHotkeyRig(
            content: textItem("hk-text-123"), chord: Chords.ctrlOpt1, frontmost: notes, switchFrontmostDuringSettle: mail)
        // when the user presses ⌃⌥1
        await rig.press(Chords.ctrlOpt1)
        // then no ⌘V was posted at all (not to Mail, not to Notes), LIB-OS-001 was reported, and the item was not replaced
        #expect(rig.keys.targets.isEmpty)
        #expect(rig.reports.errors.map(\.code) == [.libOs001])
        #expect(rig.board.text == "hk-text-123")
        #expect(rig.board.writes.count == 1)
    }

    // MARK: OC-5041 / OC-5042 (Toggle Shelf)

    private func shelfHarness(chord: Chord, shelfEnabled: Bool) -> ShelfHarness {
        ShelfHarness(chord: chord, shelfEnabled: shelfEnabled)
    }

    @MainActor private final class ShelfHarness {
        let registrar = FakeRegistrar()
        let registry: ShortcutRegistry
        let settings = SettingsStore(store: InMemoryKeyValueStore())
        var machine = ShelfRevealMachine()
        /// Every command the machine emitted, in order, as literals.
        var emitted: [String] = []
        private let when = Date(timeIntervalSinceReferenceDate: 2_000_000)

        init(chord: Chord, shelfEnabled: Bool) {
            registry = ShortcutRegistry(registrar: registrar, systemHotkeys: FakeSystemHotkeys(chords: []))
            registry.setAction(.toggleShelf) { [unowned self] in record(machine.send(.toggle(.hotkey, screen: 0), at: when)) }
            settings.set(ChordBinding.chord(chord), for: SettingKeys.shortcutsToggleShelf)
            settings.set(shelfEnabled, for: SettingKeys.shelfEnabled)
            applySettings()
        }

        func applySettings() {
            registry.applyGlobalSettings(settings)
            record(machine.send(
                .configure(enabled: settings.value(SettingKeys.shelfEnabled), placement: .rightEdge, revealOnEdgeHover: false),
                at: when))
        }

        private func record(_ commands: [ShelfRevealMachine.Command]) {
            for command in commands {
                switch command {
                case .show: emitted.append("show")
                case .hide: emitted.append("hide")
                }
            }
        }
    }

    @Test("OC-5041 with the Shelf enabled and Toggle Shelf on ⌘⇧9, two presses show the Shelf and then hide it")
    func oc5041ToggleShelfShowsThenHides() {
        // given the Shelf enabled and Toggle Shelf on ⌘⇧9 (the OC-W314-001 analogue uses ⌘J)
        let h = shelfHarness(chord: Chords.cmdShift9, shelfEnabled: true)
        #expect(h.machine.isVisible == false)
        // when the user presses ⌘⇧9 twice
        h.registrar.press(Chords.cmdShift9)
        let afterFirst = h.machine.isVisible
        h.registrar.press(Chords.cmdShift9)
        // then the first press showed the Shelf, the second hid it, and exactly those two commands were emitted
        #expect(afterFirst == true)
        #expect(h.machine.isVisible == false)
        #expect(h.emitted == ["show", "hide"])
    }

    @Test("OC-5042 with the Shelf disabled, ⌘⇧9 is not registered and shows nothing; after re-enabling it shows the Shelf")
    func oc5042DisabledShelfLeavesTheKeystrokeAlone() {
        // given Toggle Shelf bound to ⌘⇧9 and the Shelf disabled in Settings
        let h = shelfHarness(chord: Chords.cmdShift9, shelfEnabled: false)
        // when the user presses ⌘⇧9
        h.registrar.press(Chords.cmdShift9)
        // then the chord is not live (so the keystroke goes on to the front app), no Shelf command was emitted, the setting kept
        #expect(!h.registrar.liveChords.contains(Chord(keyCode: 25, modifiers: [.command, .shift])))
        #expect(h.emitted.isEmpty)
        #expect(h.machine.isVisible == false)
        #expect(h.settings.value(SettingKeys.shortcutsToggleShelf) == ChordBinding.chord(Chord(keyCode: 25, modifiers: [.command, .shift])))
        // when the user re-enables the Shelf and presses ⌘⇧9 again
        h.settings.set(true, for: SettingKeys.shelfEnabled)
        h.applySettings()
        h.registrar.press(Chords.cmdShift9)
        // then the chord is live again, the Shelf is shown, and one show command was emitted
        #expect(h.registrar.liveChords.contains(Chord(keyCode: 25, modifiers: [.command, .shift])))
        #expect(h.machine.isVisible == true)
        #expect(h.emitted == ["show"])
    }
}
