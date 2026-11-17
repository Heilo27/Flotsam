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
            return .success(try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))
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
