import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
@testable import FlotsamTriggers

// Fakes on the ports `TriggerExpander` and `TriggerEngine` use. They record what reached each port, so a test reads
// the outcome of an expansion from the pasteboard, the keyboard and the presenter rather than from internals.

/// `PasteItemStore` with a fixed load result. `beforeLoad` runs inside `content(of:)`, so a test can change the world
/// while the load is in flight.
final class ExpansionStore: PasteItemStore, @unchecked Sendable {
    private let lock = NSLock()
    private let loaded: FlotsamResult<ItemContent>
    private var _recorded: [UUID] = []
    private var _recordFailure: FlotsamError?
    private var _beforeLoad: (@Sendable () -> Void)?

    init(_ content: FlotsamResult<ItemContent>) { loaded = content }

    var recorded: [UUID] { lock.withLock { _recorded } }
    var recordFailure: FlotsamError? {
        get { lock.withLock { _recordFailure } }
        set { lock.withLock { _recordFailure = newValue } }
    }
    var beforeLoad: (@Sendable () -> Void)? {
        get { lock.withLock { _beforeLoad } }
        set { lock.withLock { _beforeLoad = newValue } }
    }

    func content(of itemId: UUID) async -> FlotsamResult<ItemContent> {
        beforeLoad?()
        return loaded
    }
    func recordPaste(of itemId: UUID) async -> FlotsamResult<Void> {
        if let failure = recordFailure { return .failure(failure) }
        lock.withLock { _recorded.append(itemId) }
        return .success(())
    }
    func delete(ids: [UUID]) async -> FlotsamResult<[UUID]> { .success(ids) }
}

/// A pasteboard another app can write to from any thread (`externalCopy`), which is what a clock hook needs.
@MainActor
final class ExpansionPasteboard: PasteboardPort {
    struct State: Sendable {
        var changeCount = 0
        var items: [PasteboardRepresentation] = []
        var writes: [[PasteboardRepresentation]] = []
        var snapshotReads = 0
        var writeFailure: FlotsamError?
    }

    private let state = LockedValue(State())

    /// Starts with the user's own clipboard.
    init(plainText: String? = nil, extraTypes: [String] = []) {
        var items: [PasteboardRepresentation] = []
        if let plainText { items.append(PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data(plainText.utf8))) }
        items += extraTypes.map { PasteboardRepresentation(uti: $0, data: Data()) }
        let initial = items
        state.withLock { $0.items = initial }
    }

    var changeCount: Int { state.value.changeCount }
    var writes: [[PasteboardRepresentation]] { state.value.writes }
    var snapshotReads: Int { state.value.snapshotReads }
    var writeFailure: FlotsamError? {
        get { state.value.writeFailure }
        set { state.withLock { $0.writeFailure = newValue } }
    }
    /// The plain text now on the pasteboard.
    var plainText: String? {
        state.value.items.first { $0.uti == "public.utf8-plain-text" }.flatMap { String(data: $0.data, encoding: .utf8) }
    }

    func currentTypeIdentifiers() -> [String] { state.value.items.map(\.uti) }
    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        state.withLock {
            $0.snapshotReads += 1
            return .success(PasteboardSnapshot(changeCount: $0.changeCount, typeIdentifiers: $0.items.map(\.uti), representations: $0.items))
        }
    }
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        state.withLock {
            if let failure = $0.writeFailure { return .failure(failure) }
            $0.items = representations
            $0.writes.append(representations)
            $0.changeCount += 1
            return .success($0.changeCount)
        }
    }

    /// Another app copies `text`.
    nonisolated func externalCopy(_ text: String) {
        state.withLock {
            $0.items = [PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data(text.utf8))]
            $0.changeCount += 1
        }
    }
}

/// Posts nothing; records each call in order, with how many own writes had reached the pasteboard at that moment.
@MainActor
final class RecordingKeys: TriggerKeyPoster {
    enum Action: Equatable {
        case key(UInt16, count: Int)
        case text(String)
        case paste
    }

    private(set) var actions: [Action] = []
    /// The process each recorded action was addressed to, parallel to `actions`.
    private(set) var targets: [FrontmostApp] = []
    var failKeyPress = false
    var failText = false
    var failPaste = false
    /// What the adapter reads as frontmost at post time; nil means no check (the app is taken to be in front).
    var frontmost: (@MainActor () -> FrontmostApp?)?
    /// Runs just before the adapter's frontmost check, so a test can change focus in the window between the
    /// expander's own check and the post.
    var beforePost: (@MainActor () -> Void)?
    /// Runs on every recorded action, so a test can change the world between two posts.
    var onAction: (() -> Void)?

    /// Mirrors the adapter: nothing is recorded unless the target is still frontmost.
    private func record(_ action: Action, to target: FrontmostApp, fail: Bool) -> Bool {
        beforePost?()
        if let frontmost, frontmost() != target { return false }
        actions.append(action)
        targets.append(target)
        onAction?()
        return !fail
    }

    func postKeyPress(keyCode: UInt16, count: Int, to target: FrontmostApp) -> Bool {
        record(.key(keyCode, count: count), to: target, fail: failKeyPress)
    }
    func postText(_ text: String, to target: FrontmostApp) -> Bool {
        record(.text(text), to: target, fail: failText)
    }
    func postPaste(to target: FrontmostApp) -> Bool {
        record(.paste, to: target, fail: failPaste)
    }
}

/// `FrontmostAppProvider` that reads the same fake the matcher's environment uses, so both agree.
@MainActor
struct EnvironmentFrontmost: FrontmostAppProvider {
    let environment: FakeKeyboardEnvironment
    func frontmost() -> FrontmostApp? { environment.frontmost }
}

/// Permissions a test grants and revokes; counts how often each was requested.
final class FakePermissions: PermissionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Set<PermissionKind> = [.accessibility, .inputMonitoring]
    private var _requested: [PermissionKind] = []

    var requested: [PermissionKind] { lock.withLock { _requested } }
    func set(_ kind: PermissionKind, granted isGranted: Bool) {
        lock.withLock { if isGranted { granted.insert(kind) } else { granted.remove(kind) } }
    }

    var isAccessibilityTrusted: Bool { isGranted(.accessibility) }
    func isGranted(_ kind: PermissionKind) -> Bool { lock.withLock { granted.contains(kind) } }
    func request(_ kind: PermissionKind) { lock.withLock { _requested.append(kind) } }
    func openSystemSettings(_ kind: PermissionKind) {}
}

struct NoRichText: RichTextCodec {
    func decode(_ representations: [PasteboardRepresentation]) -> AttributedString? { nil }
    func encode(_ text: AttributedString) -> FlotsamResult<[PasteboardRepresentation]> {
        .failure(FlotsamError(.trgOs002, "no codec in tests"))
    }
}

/// Only `fileExists` matters to expansion tests, and no test item is a file.
struct NoFiles: FileSystemPort {
    private func unused() -> FlotsamResult<Void> { .failure(FlotsamError(.sysInt001, "unused in trigger tests")) }
    func fileExists(at url: URL) -> Bool { false }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func removeItem(at url: URL) -> FlotsamResult<Void> { unused() }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { .failure(FlotsamError(.sysInt001, "unused in trigger tests")) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { nil }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func readFile(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused in trigger tests")) }
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused in trigger tests")) }
    func fileInfo(at url: URL) -> FileInfo? { nil }
    func availableCapacity(at url: URL) -> Int64? { nil }
}

@MainActor
final class RecordingPresenter: ErrorPresenter {
    private(set) var huds: [String] = []
    private(set) var notices: [Notice] = []
    func showHUD(message: String) { huds.append(message) }
    func noticesChanged(_ notices: [Notice]) { self.notices = notices }
    func presentFatal(_ error: FlotsamError) {}
}

/// Keeps every record, so a test can search the whole log.
final class RecordingSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [LogRecord] = []
    var records: [LogRecord] { lock.withLock { _records } }
    func write(_ record: LogRecord) { lock.withLock { _records.append(record) } }
    /// Everything logged, public and private text together.
    var allText: String { records.map { "\($0.publicText) \($0.privateText)" }.joined(separator: "\n") }
}

/// A full expander over fakes. Defaults: the user is in an ordinary editor, has "previous clipboard" copied, and
/// nothing fails.
@MainActor
final class ExpanderHarness {
    static let app = FrontmostApp(bundleId: "com.example.editor", processId: 100)
    static let itemId = UUID()

    let store: ExpansionStore
    let pasteboard: ExpansionPasteboard
    let keys = RecordingKeys()
    let environment = FakeKeyboardEnvironment()
    let permissions = FakePermissions()
    let snapshot = TriggerSnapshotStore()
    let clock = ManualClock()
    let presenter = RecordingPresenter()
    let sink = RecordingSink()
    let reporter: ErrorReporter
    let expander: TriggerExpander

    init(
        content: FlotsamResult<ItemContent> = .success(
            ItemContent(kind: .text, plainText: "expanded text", representations: [], members: [])),
        clipboard: String? = "previous clipboard", clipboardTypes: [String] = []
    ) {
        store = ExpansionStore(content)
        pasteboard = ExpansionPasteboard(plainText: clipboard, extraTypes: clipboardTypes)
        reporter = ErrorReporter(presenter: presenter, clock: clock, sink: sink)
        let ledger = OwnWriteLedger()
        let preserver = ClipboardPreserver(pasteboard: pasteboard, ownWrites: ledger, clock: clock)
        let paste = PasteService(
            store: store, pasteboard: pasteboard, files: NoFiles(), frontmost: EnvironmentFrontmost(environment: environment),
            accessibility: permissions, keys: keys, clock: clock, ownWrites: ledger)
        expander = TriggerExpander(
            store: store, pasteboard: pasteboard, files: NoFiles(), codec: NoRichText(), preserver: preserver,
            ownWrites: ledger, paste: paste, keys: keys, keyboard: environment, snapshot: snapshot,
            permissions: permissions, reporter: reporter, clock: clock, ownBundleId: "com.example.flotsam",
            calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"), sink: sink)
        environment.frontmost = Self.app
        keys.frontmost = { [environment] in environment.frontmost }
    }

    /// The match the matcher would have produced for the trigger "sig" and a Space.
    func match(typed: String = "sig", boundary: UInt16 = TriggerKeys.space, app: FrontmostApp = ExpanderHarness.app) -> TriggerMatch {
        TriggerMatch(
            itemId: Self.itemId, typedText: typed, triggerLength: typed.count, boundaryKeyCode: boundary, app: app)
    }

    /// Codes the reporter recorded (Warning and above), oldest first.
    func reportedCodes() async -> [ErrorCode] { await reporter.recentErrors().map(\.code) }
}
