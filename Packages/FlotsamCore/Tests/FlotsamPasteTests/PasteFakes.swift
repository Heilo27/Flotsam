import Foundation
import FlotsamBase
import FlotsamStorage
@testable import FlotsamPaste

/// Fakes on the paste ports, so the sequence is observed through what reaches the pasteboard, the panel and the keyboard.

final class FakeStore: PasteItemStore, @unchecked Sendable {
    private let lock = NSLock()
    private let loaded: FlotsamResult<ItemContent>
    private var _recorded: [UUID] = []
    private var _deleted: [[UUID]] = []
    private var _recordFailure: FlotsamError?

    init(_ content: FlotsamResult<ItemContent>) { loaded = content }

    var recorded: [UUID] { lock.withLock { _recorded } }
    var deleted: [[UUID]] { lock.withLock { _deleted } }
    var recordFailure: FlotsamError? {
        get { lock.withLock { _recordFailure } }
        set { lock.withLock { _recordFailure = newValue } }
    }

    func content(of itemId: UUID) async -> FlotsamResult<ItemContent> { loaded }
    func recordPaste(of itemId: UUID) async -> FlotsamResult<Void> {
        if let failure = recordFailure { return .failure(failure) }
        lock.withLock { _recorded.append(itemId) }
        return .success(())
    }
    func delete(ids: [UUID]) async -> FlotsamResult<[UUID]> {
        lock.withLock { _deleted.append(ids) }
        return .success(ids)
    }
}

/// Only `fileExists` matters to paste; the rest is unused and fails.
struct FakeFiles: FileSystemPort {
    var existing: Set<String>
    func fileExists(at url: URL) -> Bool { existing.contains(url.path) }
    private func unused() -> FlotsamResult<Void> { .failure(FlotsamError(.sysInt001, "unused in paste tests")) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { unused() }
    func removeItem(at url: URL) -> FlotsamResult<Void> { unused() }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { .failure(FlotsamError(.sysInt001, "unused in paste tests")) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { nil }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { unused() }
    func readFile(at url: URL) -> FlotsamResult<Data> { .failure(FlotsamError(.sysInt001, "unused in paste tests")) }
    func fileInfo(at url: URL) -> FileInfo? { nil }
    func availableCapacity(at url: URL) -> Int64? { nil }
}

@MainActor
final class FakePasteboard: PasteboardPort {
    private(set) var changeCount = 0
    private(set) var written: [[PasteboardRepresentation]] = []
    var failWith: FlotsamError?

    func currentTypeIdentifiers() -> [String] { written.last?.map(\.uti) ?? [] }
    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot> {
        .success(PasteboardSnapshot(changeCount: changeCount, typeIdentifiers: currentTypeIdentifiers(), representations: written.last ?? []))
    }
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int> {
        if let failWith { return .failure(failWith) }
        written.append(representations)
        changeCount += 1
        return .success(changeCount)
    }
}

/// Frontmost app that becomes `target` after `pollsUntilTarget` calls (nil: never).
@MainActor
final class FakeFrontmost: FrontmostAppProvider {
    let target: FrontmostApp
    let pollsUntilTarget: Int?
    private(set) var polls = 0
    init(target: FrontmostApp, pollsUntilTarget: Int? = 0) {
        self.target = target
        self.pollsUntilTarget = pollsUntilTarget
    }
    func frontmost() -> FrontmostApp? {
        defer { polls += 1 }
        if let pollsUntilTarget, polls >= pollsUntilTarget { return target }
        return FrontmostApp(bundleId: "com.example.other", processId: 999)
    }
}

struct FakePermission: PermissionProbe {
    var isAccessibilityTrusted: Bool
}

@MainActor
final class FakeKeys: KeyEventPoster {
    var succeeds = true
    private(set) var posts = 0
    func postPaste() -> Bool { posts += 1; return succeeds }
}

/// Panel that is visible until hidden, unless `staysVisible`.
@MainActor
final class FakeHost: PasteHost {
    var staysVisible = false
    private(set) var visible = true
    private(set) var hides = 0
    var isPanelVisible: Bool { visible }
    func hidePanel() { hides += 1; visible = staysVisible }
}

/// Records sleeps instead of waiting.
final class RecordingClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _slept: [Duration] = []
    var slept: [Duration] { lock.withLock { _slept } }
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(for duration: Duration) async { lock.withLock { _slept.append(duration) } }
}
