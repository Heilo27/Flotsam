import Foundation
@testable import FlotsamBase

/// Shared fakes and file helpers for the FRD-000 suites. Fakes sit on the ports (ErrorPresenter, WallClock,
/// PasteboardPort, DiagnosticsDataSource, KeyValueStore) so tests observe what the user would see, not internals.

/// Manual clock: tests advance it, nothing sleeps.
final class ManualClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    func now() -> Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func sleep(for duration: Duration) async throws {}
}

/// Records everything the reporter draws. `notices` is the last list the menu-bar Notices submenu would show.
@MainActor
final class RecordingPresenter: ErrorPresenter {
    private(set) var huds: [String] = []
    private(set) var notices: [Notice] = []
    private(set) var noticeUpdates = 0
    private(set) var fatals: [FlotsamError] = []

    func showHUD(message: String) { huds.append(message) }
    func noticesChanged(_ notices: [Notice]) { self.notices = notices; noticeUpdates += 1 }
    func presentFatal(_ error: FlotsamError) { fatals.append(error) }
}

/// In-memory `KeyValueStore`.
final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

struct FakeDataSource: DiagnosticsDataSource {
    var permissions: [PermissionName: PermissionState] = [:]
    var counts: [ItemKind: Int] = [:]
    var bytes: (database: Int, blobs: Int) = (0, 0)

    func permissionStates() async -> [PermissionName: PermissionState] { permissions }
    func itemCounts() async -> [ItemKind: Int] { counts }
    func storageBytes() async -> (database: Int, blobs: Int) { bytes }
}

/// Fake general pasteboard. `failWith` makes `write` fail the way `NSPasteboard` can.
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

enum Repo {
    /// Package root (`Packages/FlotsamCore`): Tests/FlotsamBaseTests/<file> up three levels.
    static func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Repository root: package root up two more levels.
    static func root(file: String = #filePath) -> URL {
        packageRoot(file: file).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The shipped string catalogue, `key -> en value`, read straight from the JSON on disk.
    static func catalogue(file: String = #filePath) throws -> [String: String] {
        let url = packageRoot(file: file).appendingPathComponent("Sources/FlotsamBase/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = json?["strings"] as? [String: [String: Any]] ?? [:]
        return strings.compactMapValues { entry in
            let en = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
            return (en?["stringUnit"] as? [String: Any])?["value"] as? String
        }
    }

    static func catalogueSourceLanguage(file: String = #filePath) throws -> String? {
        let url = packageRoot(file: file).appendingPathComponent("Sources/FlotsamBase/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return json?["sourceLanguage"] as? String
    }
}

extension FlotsamError {
    /// Convenience for reporter tests: an error with a fixed static message and no context.
    static func raised(_ code: ErrorCode) -> FlotsamError { FlotsamError(code, "test") }
}
