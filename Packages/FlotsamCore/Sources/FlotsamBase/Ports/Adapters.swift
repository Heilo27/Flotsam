import Foundation

/// `FileManager`-backed `FileSystemPort`. Foundation only, so it lives in Base.
public struct LocalFileSystem: FileSystemPort {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> {
        attempt { try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: permissions]) }
    }

    public func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> {
        attempt { try FileManager.default.copyItem(at: source, to: destination) }
    }

    public func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> {
        attempt { try FileManager.default.moveItem(at: source, to: destination) }
    }

    public func removeItem(at url: URL) -> FlotsamResult<Void> {
        attempt { try FileManager.default.removeItem(at: url) }
    }

    public func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> {
        do {
            // `contentsOfDirectory(at:)` fails with NSCocoa 256 "Not a directory" on a link to a folder, so the folder
            // itself is resolved first. Entries inside it are not touched: a link among them is still listed as a link.
            let folder = url.resolvingSymlinksInPath()
            return .success(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
        } catch {
            return .failure(Self.mapped(error))
        }
    }

    public func extendedAttribute(named name: String, at url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, name, &buffer, size, 0, 0)
        return read >= 0 ? Data(buffer.prefix(read)) : nil
    }

    public func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> {
        // Created with the final permissions (never world-readable, even briefly), then fsync'd.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(permissions))
        guard descriptor >= 0 else { return .failure(Self.posixFailure(errno)) }
        defer { close(descriptor) }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return .failure(Self.posixFailure(errno))
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else { return .failure(Self.posixFailure(errno)) }
        return .success(())
    }

    public func readFile(at url: URL) -> FlotsamResult<Data> {
        do { return .success(try Data(contentsOf: url)) } catch { return .failure(Self.mapped(error)) }
    }

    public func fileInfo(at url: URL) -> FileInfo? {
        // `attributesOfItem` does not follow a symbolic link, so a link reports `.symbolicLink`, not its target.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let kind: FileKind =
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular?: .regular
            case .typeDirectory?: .directory
            case .typeSymbolicLink?: .symbolicLink
            default: .other
            }
        return FileInfo(
            byteSize: size, modifiedAt: modified, createdAt: attributes[.creationDate] as? Date, kind: kind)
    }

    public func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func posixFailure(_ code: Int32) -> FlotsamError {
        FlotsamError(
            .sysInt001, "File write failed", underlying: UnderlyingErrorInfo(domain: NSPOSIXErrorDomain, code: Int(code)))
    }

    private func attempt(_ operation: () throws -> Void) -> FlotsamResult<Void> {
        do {
            try operation()
            return .success(())
        } catch {
            return .failure(Self.mapped(error))
        }
    }

    // Generic mapping; callers that know the failing area (Storage) re-wrap with their own code.
    private static func mapped(_ error: Error) -> FlotsamError {
        let nsError = error as NSError
        return FlotsamError(
            .sysInt001, "File system operation failed",
            underlying: UnderlyingErrorInfo(domain: nsError.domain, code: nsError.code))
    }
}

/// `UserDefaults`-backed `KeyValueStore` (UserDefaults is thread-safe).
public struct UserDefaultsStore: KeyValueStore {
    // Allowed unsafe-sendability exception (c), ADR-0004: Apple documents UserDefaults as thread-safe.
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func setString(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
    public func removeValue(forKey key: String) { defaults.removeObject(forKey: key) }
}

extension KeyValueStore where Self == UserDefaultsStore {
    /// The app's settings store, named so callers outside this file never spell the UserDefaults type (ADR-0009).
    public static var standard: UserDefaultsStore { UserDefaultsStore() }
}

/// `com.apple.screencapture` read through CFPreferences. Synchronises before each read so a `defaults write` made
/// while Flotsam runs is seen at the next re-resolution (FR-002-02).
public struct SystemScreenCapturePreferences: ScreenCapturePreferences {
    private static let domain = "com.apple.screencapture"

    public init() {}

    public func location() -> String? { Self.string("location") }
    public func name() -> String? { Self.string("name") }

    private static func string(_ key: String) -> String? {
        CFPreferencesAppSynchronize(domain as CFString)
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
}
