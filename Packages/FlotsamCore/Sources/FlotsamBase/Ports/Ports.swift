import Foundation

// Ports: the seams between FlotsamCore and the system (ADR-0011). Real adapters live in the app target's
// Platform folder, except the Foundation-only ones in this module (file system and key-value store, see Adapters.swift).

/// Time. Tests advance a manual clock instead of sleeping.
public protocol WallClock: Sendable {
    func now() -> Date
    /// Suspends for `duration`. Never throws: on task cancellation it returns early, so a caller that must stop on
    /// cancellation checks `Task.isCancelled` after the call.
    func sleep(for duration: Duration) async
}

public struct SystemClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for duration: Duration) async {
        // Cancellation is the only error Task.sleep throws; the port contract is to return early (callers check Task.isCancelled).
        try? await Task.sleep(for: duration)
    }
}

/// One pasteboard representation: a UTI and its bytes.
public struct PasteboardRepresentation: Sendable, Equatable {
    public let uti: String
    public let data: Data

    public init(uti: String, data: Data) {
        self.uti = uti
        self.data = data
    }
}

public struct PasteboardSnapshot: Sendable, Equatable {
    public let changeCount: Int
    public let typeIdentifiers: [String]
    public let representations: [PasteboardRepresentation]

    public init(changeCount: Int, typeIdentifiers: [String], representations: [PasteboardRepresentation]) {
        self.changeCount = changeCount
        self.typeIdentifiers = typeIdentifiers
        self.representations = representations
    }
}

/// The general pasteboard. Main-actor because `NSPasteboard` thread safety is unverified (ADR-0004 open item).
@MainActor
public protocol PasteboardPort {
    var changeCount: Int { get }
    /// Type identifiers only, no bytes. Gates 2 to 4 of FR-001-04 use this.
    func currentTypeIdentifiers() -> [String]
    func readSnapshot(types: [String]) -> FlotsamResult<PasteboardSnapshot>
    /// Writes the representations and returns the resulting `changeCount`.
    func write(_ representations: [PasteboardRepresentation]) -> FlotsamResult<Int>
}

/// String-valued key-value storage behind `SettingsStore`. Only `SettingsStore` may use it for settings (ADR-0009).
public protocol KeyValueStore: Sendable {
    func string(forKey key: String) -> String?
    func setString(_ value: String, forKey key: String)
    func removeValue(forKey key: String)
}

/// Filesystem subset used by Storage and Screenshots.
public protocol FileSystemPort: Sendable {
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void>
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void>
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void>
    func removeItem(at url: URL) -> FlotsamResult<Void>
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]>
    func extendedAttribute(named name: String, at url: URL) -> Data?
    /// Writes `data` to `url` with the given POSIX permissions and flushes it to disk before returning, so a
    /// following rename publishes a complete file (FR-007-04).
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void>
    func readFile(at url: URL) -> FlotsamResult<Data>
    /// Size and modification time, nil when the file does not exist. Reconcile uses the age; budget uses neither.
    func fileInfo(at url: URL) -> FileInfo?
    /// Bytes available for important usage on the volume holding `url` (FR-007-14); nil when unknown.
    func availableCapacity(at url: URL) -> Int64?
}

/// What a directory entry is, read without following a symbolic link.
public enum FileKind: Sendable, Equatable {
    case regular, directory, symbolicLink, other
}

/// Size, dates and kind of one file. `createdAt` is the birth date; screenshot pickup orders and filters by it
/// (FRD-002 FR-002-08, FR-002-09). Nil when the volume does not record one.
public struct FileInfo: Sendable, Equatable {
    public let byteSize: Int
    public let modifiedAt: Date
    public let createdAt: Date?
    public let kind: FileKind

    public init(byteSize: Int, modifiedAt: Date, createdAt: Date? = nil, kind: FileKind = .regular) {
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.kind = kind
    }
}

/// The system screenshot preferences (`com.apple.screencapture`), read fresh on every call because the user can
/// change them with `defaults write` or the Screenshot app while Flotsam runs (FRD-002 FR-002-01, FR-002-02).
public protocol ScreenCapturePreferences: Sendable {
    /// The `location` value as stored (may start with `~`); nil when unset.
    func location() -> String?
    /// The `name` value (the file-name prefix the user chose); nil when unset.
    func name() -> String?
}
