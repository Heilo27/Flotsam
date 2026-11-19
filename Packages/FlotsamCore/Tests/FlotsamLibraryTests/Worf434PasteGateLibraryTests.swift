import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamLibrary

// TASK-434 (Worf, blind): the Library paste path and footer, driven end to end through the REAL `PasteService` and the
// real `PermissionProbe.isAccessibilityTrusted` wiring the app uses (AppContainer), over fakes on the system ports.
// Contract: OC-8119 (frd-008), OC-3103 (frd-003), FR-003-17, FR-003-18, FR-008-14.

/// A probe whose Accessibility answer a test flips at runtime. Deliberately does NOT declare `isAccessibilityTrusted`:
/// the footer must go through the shared extension on `PermissionProbe`, not a fake's own shortcut.
private final class W434Probe: PermissionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var accessibility: Bool
    init(accessibility: Bool) { self.accessibility = accessibility }
    func set(accessibility value: Bool) { lock.withLock { accessibility = value } }
    func isGranted(_ kind: PermissionKind) -> Bool { kind == .accessibility ? lock.withLock { accessibility } : false }
    func request(_ kind: PermissionKind) {}
    func openSystemSettings(_ kind: PermissionKind) {}
}

private final class W434Store: PasteItemStore, @unchecked Sendable {
    private let lock = NSLock()
    private let content: ItemContent
    private var _recorded: [UUID] = []
    init(content: ItemContent) { self.content = content }
    var recorded: [UUID] { lock.withLock { _recorded } }
    func content(of itemId: UUID) async -> FlotsamResult<ItemContent> { .success(content) }
    func recordPaste(of itemId: UUID) async -> FlotsamResult<Void> { lock.withLock { _recorded.append(itemId) }; return .success(()) }
    func delete(ids: [UUID]) async -> FlotsamResult<[UUID]> { .success(ids) }
}

private struct W434NoFiles: FileSystemPort {
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

@MainActor
private final class W434Board: PasteboardPort {
    private(set) var changeCount = 0
    private(set) var writes: [[PasteboardRepresentation]] = []
    func currentTypeIdentifiers() -> [String] { writes.last?.map(\.uti) ?? [] }
    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        .success(PasteboardSnapshot(changeCount: changeCount, typeIdentifiers: currentTypeIdentifiers(), representations: writes.last ?? []))
    }
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        writes.append(representations)
        changeCount += 1
        return .success(changeCount)
    }
    /// The plain text the user would get from ⌘V right now.
    var text: String? {
        writes.last?.first { $0.uti == "public.utf8-plain-text" }.flatMap { String(data: $0.data, encoding: .utf8) }
    }
}

@MainActor
private struct W434Frontmost: FrontmostAppProvider {
    let app: FrontmostApp
    func frontmost() -> FrontmostApp? { app }
}

@MainActor
private final class W434Keys: KeyEventPoster {
    private(set) var targets: [FrontmostApp] = []
    func postPaste(to target: FrontmostApp) -> Bool { targets.append(target); return true }
}

private struct W434InstantClock: WallClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(for duration: Duration) async {}
}

private let textEditApp = FrontmostApp(bundleId: "com.apple.TextEdit", processId: 4242)

/// A real `PasteService` and a real `LibraryViewModel`, joined the way `AppContainer` joins them.
@MainActor
private struct W434Rig {
    let probe: W434Probe
    let board = W434Board()
    let keys = W434Keys()
    let store: W434Store
    let host = FakeHost()
    let model: LibraryViewModel
    let reported: Harness.Reported

    init(accessibility: Bool, itemText: String = "oracle-x") {
        probe = W434Probe(accessibility: accessibility)
        let text = PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data(itemText.utf8))
        store = W434Store(content: ItemContent(kind: .text, plainText: itemText, representations: [text], members: []))
        let service = PasteService(
            store: store, pasteboard: board, files: W434NoFiles(), frontmost: W434Frontmost(app: textEditApp),
            accessibility: probe, keys: keys, clock: W434InstantClock(), ownWrites: OwnWriteLedger())
        let reported = Harness.Reported()
        self.reported = reported
        let probe = probe
        model = LibraryViewModel(
            source: FakeSource(rows: [makeRow(1)]), paster: service, host: host, preferences: FakePreferences(),
            effects: LibraryEffects(
                report: { reported.errors.append($0) }, isAccessibilityTrusted: { probe.isAccessibilityTrusted }))
    }

    static let itemId = makeRow(1).id
}

@MainActor
@Suite("TASK-434 Library paste and footer through PasteGate")
struct Worf434PasteGateLibraryTests {
    private static let hudText = "Accessibility is off, so Flotsam can't paste for you. The item is on your clipboard; press ⌘V."

    /// OC-8119 / OC-3103 / FR-003-17. given Accessibility untrusted and the Library open over TextEdit, when the user
    /// chooses item X, then no ⌘V is posted, X is on the pasteboard (once), exactly one SET-PRM-001 is reported with
    /// the item id, and its HUD text is the catalogue sentence. Red if `PasteService.paste` ignores the gate (a ⌘V is
    /// posted), if the gate stops copying first, or if `LibraryViewModel.paste` raises the wrong or no code.
    @Test("OC-8119 untrusted: Library paste lands on copy-only with SET-PRM-001 and the item on the clipboard")
    func untrustedLibraryPasteIsCopyOnly() async {
        let rig = W434Rig(accessibility: false)
        await rig.model.open(target: textEditApp)

        await rig.model.paste(itemId: W434Rig.itemId, mode: .paste)

        #expect(rig.keys.targets.isEmpty)
        #expect(rig.board.writes.count == 1)
        #expect(rig.board.text == "oracle-x")
        #expect(rig.reported.errors.count == 1)
        #expect(rig.reported.errors.first?.code == .setPrm001)
        #expect(rig.reported.errors.first?.context[.itemId] == .id(W434Rig.itemId))
        #expect(rig.reported.errors.first.map { FlotsamStrings.message(for: $0) } == Self.hudText)
        #expect(rig.store.recorded == [W434Rig.itemId])
    }

    /// FR-003-15 mode ⌥Return with Accessibility off is also copy-only with the same error. Red if the plain-text mode
    /// bypasses the gate.
    @Test("OC-8119 untrusted: plain-text paste is also copy-only with SET-PRM-001")
    func untrustedPlainTextPasteIsCopyOnly() async {
        let rig = W434Rig(accessibility: false)
        await rig.model.open(target: textEditApp)

        await rig.model.paste(itemId: W434Rig.itemId, mode: .plainText)

        #expect(rig.keys.targets.isEmpty)
        #expect(rig.board.text == "oracle-x")
        #expect(rig.reported.errors.map(\.code) == [.setPrm001])
    }

    /// FR-003-15 ⇧Return, the explicit copy. given Accessibility untrusted, then it copies and reports NOTHING (the user
    /// asked for copy-only; SET-PRM-001 would be noise). Red if the gate is applied before the copy-only mode check.
    @Test("negative: explicit copy-only mode with Accessibility off reports no error")
    func explicitCopyOnlyReportsNothing() async {
        let rig = W434Rig(accessibility: false)
        await rig.model.open(target: textEditApp)

        await rig.model.paste(itemId: W434Rig.itemId, mode: .copyOnly)

        #expect(rig.keys.targets.isEmpty)
        #expect(rig.board.text == "oracle-x")
        #expect(rig.reported.errors.isEmpty)
    }

    /// FR-003-15 / OC-8119 inverse. given Accessibility trusted, when the user chooses X, then X is pasted: one ⌘V
    /// addressed to TextEdit, X on the pasteboard, no error. Red if the gate returns copy-only for a trusted probe.
    @Test("trusted: Library paste posts one ⌘V to the target and reports nothing")
    func trustedLibraryPastePastes() async {
        let rig = W434Rig(accessibility: true)
        await rig.model.open(target: textEditApp)

        await rig.model.paste(itemId: W434Rig.itemId, mode: .paste)

        #expect(rig.keys.targets == [textEditApp])
        #expect(rig.board.text == "oracle-x")
        #expect(rig.reported.errors.isEmpty)
    }

    /// FR-003-18 / OC-8119. given Accessibility untrusted, then the footer notice reads 'Press ⌘V to paste' and the
    /// second hint is ⌘C Copy; given trusted, no notice and the second hint is ⌥Return Plain text. Red if the
    /// footer stops asking the shared probe extension, or swaps the branches.
    @Test("footer: untrusted shows the copy-only notice and the ⌘C hint; trusted shows neither")
    func footerFollowsAccessibility() {
        let untrusted = W434Rig(accessibility: false).model.footer()
        let trusted = W434Rig(accessibility: true).model.footer()

        #expect(untrusted.notice == "Press ⌘V to paste")
        #expect(untrusted.hints.map(\.key) == ["Return", "⌘C", "Space"])
        #expect(untrusted.hints[1].label == "Copy")
        #expect(trusted.notice == nil)
        #expect(trusted.hints[1].key == "⌥Return")
        #expect(trusted.hints[1].label == "Plain text")
    }

    /// FR-008-13 rule b: state is read fresh, never cached. given a footer read while untrusted, when Accessibility is
    /// granted afterwards, then the next footer and the next paste both see trusted. Red if either caches the first
    /// answer.
    @Test("fresh read: granting Accessibility mid-session flips the footer and the next paste")
    func grantingMidSessionTakesEffectImmediately() async {
        let rig = W434Rig(accessibility: false)
        await rig.model.open(target: textEditApp)
        #expect(rig.model.footer().notice == "Press ⌘V to paste")

        rig.probe.set(accessibility: true)
        await rig.model.paste(itemId: W434Rig.itemId, mode: .paste)

        #expect(rig.model.footer().notice == nil)
        #expect(rig.keys.targets == [textEditApp])
        #expect(rig.reported.errors.isEmpty)
    }
}
