import Foundation
import os
import Testing
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
    func sleep(for duration: Duration) async {}
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

    /// The shipped string catalogue, `key -> en value`, read through the production reader (`FlotsamCatalogue`), so the
    /// tests and the app parse the format one way (Rule 9). A read failure fails the calling test.
    static func catalogue() throws -> [String: String] {
        try FlotsamCatalogue.englishStrings(at: shippedCatalogueURL).get()
    }

    /// The shipped catalogue's location, resolved by the production `FlotsamCatalogue.shippedURL(file:)` rule. The
    /// production default argument `#filePath` is expanded in the CALLER's file, so a call from the tests would resolve
    /// to `Tests/Resources/`; passing the production source file explicitly gives the rule its intended anchor.
    static var shippedCatalogueURL: URL {
        FlotsamCatalogue.shippedURL(file: packageRoot().appendingPathComponent("Sources/FlotsamBase/Strings/FlotsamCatalogue.swift").path)
    }

    /// `sourceLanguage` of the shipped catalogue. The file location comes from `FlotsamCatalogue`, not a second path.
    static func catalogueSourceLanguage() throws -> String? {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Repo.shippedCatalogueURL)) as? [String: Any]
        return json?["sourceLanguage"] as? String
    }
}

/// Records every `LogRecord` written to it, in arrival order. The lock makes it safe to share with the reporter actor;
/// `OSAllocatedUnfairLock` is itself `Sendable`, so the compiler checks this class (no `@unchecked`).
final class RecordingLogSink: LogSink {
    private let storage = OSAllocatedUnfairLock<[LogRecord]>(initialState: [])

    func write(_ record: LogRecord) { storage.withLock { $0.append(record) } }

    var records: [LogRecord] { storage.withLock { $0 } }
}

/// The FR-000-07 consistency check, run against any catalogue and any code list: every non-Info code has a message of
/// at most 140 characters, no Info code has one, every `error.` key has a code, no two codes share a raw value, and the
/// argument kinds each code declares match the specifiers in its template (`FlotsamStrings.argumentKindViolations`).
/// Returns one tag per violation (empty means consistent) so a test can feed a mutated catalogue and name what broke.
enum CatalogueConsistency {
    static let maxMessageLength = 140

    static func violations(
        catalogue: [String: String],
        codes: [(raw: String, severity: ErrorSeverity)]
    ) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for code in codes where !seen.insert(code.raw).inserted { found.append("duplicate:\(code.raw)") }
        let keys = Set(codes.map { "error.\($0.raw)" })
        for code in codes {
            let key = "error.\(code.raw)"
            let message = catalogue[key]
            if code.severity == .info {
                if message != nil { found.append("infoHasMessage:\(key)") }
            } else if let message {
                if message.count > maxMessageLength { found.append("tooLong:\(key)") }
            } else {
                found.append("missing:\(key)")
            }
        }
        for key in catalogue.keys where key.hasPrefix("error.") && !keys.contains(key) { found.append("orphan:\(key)") }
        let enumCodes = Set(codes.compactMap { ErrorCode(rawValue: $0.raw) })
        found += FlotsamStrings.argumentKindViolations(catalogue: catalogue, codes: Array(enumCodes))
        return found.sorted()
    }

    /// The shipped enum as the checker's input.
    static var shippedCodes: [(raw: String, severity: ErrorSeverity)] {
        ErrorCode.allCases.map { (raw: $0.rawValue, severity: $0.severity) }
    }

    /// Bytes of the shipped catalogue after `edit` has changed its `strings` table. The mutation is applied to the real
    /// file's JSON, so everything the edit does not touch stays exactly as shipped.
    static func mutatedShippedData(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: Repo.shippedCatalogueURL)) as? [String: Any]
        )
        var strings = try #require(root["strings"] as? [String: Any])
        edit(&strings)
        root["strings"] = strings
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// A catalogue entry with only an English value.
    static func entry(_ value: String) -> [String: Any] {
        ["localizations": ["en": ["stringUnit": ["state": "translated", "value": value]]]]
    }
}

extension FlotsamError {
    /// Convenience for reporter tests: an error with a fixed static message and no context.
    static func raised(_ code: ErrorCode) -> FlotsamError { FlotsamError(code, "test") }
}
