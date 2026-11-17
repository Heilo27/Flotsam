import Foundation
import FlotsamBase

/// System screenshot preferences as the test says.
struct FixedPreferences: ScreenCapturePreferences {
    var locationValue: String?
    var nameValue: String?
    func location() -> String? { locationValue }
    func name() -> String? { nameValue }
}

/// A clock whose `sleep` advances time instantly.
final class ManualClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    func now() -> Date { lock.withLock { current } }
    func sleep(for duration: Duration) async {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// The local file system, except `fileInfo` for one path follows a script indexed by the clock: the file changes
/// until `settlesAt`, then holds. `vanishesAt` makes it disappear.
final class GrowingFileSystem: FileSystemPort, @unchecked Sendable {
    private let real = LocalFileSystem()
    let clock: ManualClock
    let start: Date
    let settlesAfter: TimeInterval
    let vanishesAfter: TimeInterval?

    init(clock: ManualClock, settlesAfter: TimeInterval, vanishesAfter: TimeInterval? = nil) {
        self.clock = clock
        self.start = clock.now()
        self.settlesAfter = settlesAfter
        self.vanishesAfter = vanishesAfter
    }

    func fileInfo(at url: URL) -> FileInfo? {
        let elapsed = clock.now().timeIntervalSince(start)
        if let vanishesAfter, elapsed >= vanishesAfter { return nil }
        let growth = min(elapsed, settlesAfter)
        let size = 1_000 + Int(growth * 1_000)
        return FileInfo(byteSize: size, modifiedAt: start.addingTimeInterval(growth), createdAt: start)
    }

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) -> FlotsamResult<Void> { real.createDirectory(at: url, permissions: permissions) }
    func copyItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) -> FlotsamResult<Void> { real.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) -> FlotsamResult<Void> { real.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) -> FlotsamResult<[URL]> { real.contentsOfDirectory(at: url) }
    func extendedAttribute(named name: String, at url: URL) -> Data? { real.extendedAttribute(named: name, at: url) }
    func writeFile(_ data: Data, to url: URL, permissions: Int) -> FlotsamResult<Void> { real.writeFile(data, to: url, permissions: permissions) }
    func readFile(at url: URL) -> FlotsamResult<Data> { real.readFile(at: url) }
    func availableCapacity(at url: URL) -> Int64? { real.availableCapacity(at: url) }
}

/// A temporary folder tree, removed by `cleanUp`.
struct TempFolder {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotsam-ssp-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ path: String, bytes: Data = Data([0x89, 0x50, 0x4E, 0x47]), screenCapture: Bool? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        if let screenCapture { try Self.setScreenCaptureAttribute(screenCapture, on: url) }
        return url
    }

    /// Writes the attribute the way macOS does: a binary property list holding a boolean.
    static func setScreenCaptureAttribute(_ value: Bool, on url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let result = data.withUnsafeBytes { buffer in
            setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", buffer.baseAddress, data.count, 0, 0)
        }
        if result != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    static func screenCaptureAttribute(_ value: Bool) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)) ?? Data()
    }
}
