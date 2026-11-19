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

/// Whether macOS currently lets Flotsam read what other apps copy (FRD-001 FR-001-18 a). Separate from
/// `PasteboardPort` because it is a system privacy setting, not part of reading or writing the board.
@MainActor
public protocol PasteboardAccessPort {
    /// False when the system reports an access behaviour other than "Allow" (the setting exists on every supported macOS).
    var isReadAllowed: Bool { get }
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
    /// Moves `source` over `destination` in one step: a reader sees the old file or the new one, never neither.
    /// `moveItem` fails onto an existing path, and removing first leaves a gap in which the file does not exist.
    /// The default below is that two-step form and is NOT atomic: for a test fake that only models the other
    /// operations. Every real conformer must override it with a single `rename(2)`, as `LocalFileSystem` does.
    func replaceItem(at destination: URL, with source: URL) -> FlotsamResult<Void>
    func removeItem(at url: URL) -> FlotsamResult<Void>
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]>
    func extendedAttribute(named name: String, at url: URL) -> Data?
    /// Writes `data` to `url` with the given POSIX permissions and flushes it to disk before returning, so a
    /// following rename publishes a complete file (FR-007-04).
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void>
    func readFile(at url: URL) -> FlotsamResult<Data>
    /// Reads a file the caller does not trust to be what it was a moment ago (a screenshot in a user-writable folder,
    /// FRD-002 FR-002-16): opens it with `O_NOFOLLOW`, requires the opened descriptor to be a regular file, and reads
    /// from that descriptor, so a swap for a link after any earlier check cannot be read through. A link or a
    /// non-regular file fails with `FlotsamError.isLinkOrNotRegularFile`; anything else (vanished, unreadable) is an
    /// ordinary failure.
    func readFileNoFollow(at url: URL) -> FlotsamResult<Data>
    /// Size and modification time, nil when the file does not exist. Reconcile uses the age; budget uses neither.
    func fileInfo(at url: URL) -> FileInfo?
    /// Bytes available for important usage on the volume holding `url` (FR-007-14); nil when unknown.
    func availableCapacity(at url: URL) -> Int64?
}

extension FileSystemPort {
    /// Not atomic: removes the destination, then moves (a reader can see neither file in between). Only test fakes use
    /// this; production's `LocalFileSystem` overrides it with `rename(2)`. Do not rely on it for crash safety.
    public func replaceItem(at destination: URL, with source: URL) -> FlotsamResult<Void> {
        if fileExists(at: destination), case .failure(let error) = removeItem(at: destination) { return .failure(error) }
        return moveItem(at: source, to: destination)
    }
}

extension FlotsamError {
    /// The failure `readFileNoFollow` reports for a symbolic link (`ELOOP`) or a file that is not regular (`EFTYPE`).
    public var isLinkOrNotRegularFile: Bool {
        guard let underlying, underlying.domain == NSPOSIXErrorDomain else { return false }
        return underlying.code == Int(ELOOP) || underlying.code == Int(EFTYPE)
    }
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
