import FlotsamBase
import Foundation

/// FR-002-07: a candidate is imported only once its size and modification date are unchanged across two checks
/// 0.5 s apart; a file still changing after 5 s is skipped as `SSP-IO-002` (the caller puts it on the retry list).
/// Readability is proved by the import's single read of the bytes, so it is not checked twice.
public struct StabilityCheck: Sendable {
    public static let interval: Duration = .milliseconds(500)
    public static let limit: TimeInterval = 5

    private let fileSystem: any FileSystemPort
    private let clock: any WallClock

    public init(fileSystem: any FileSystemPort, clock: any WallClock) {
        self.fileSystem = fileSystem
        self.clock = clock
    }

    /// Returns the settled size and dates, or `SSP-IO-002` when the file vanished, never settled within the limit,
    /// or the task was cancelled.
    public func waitUntilStable(_ url: URL) async -> FlotsamResult<FileInfo> {
        let start = clock.now()
        guard var previous = fileSystem.fileInfo(at: url) else { return .failure(Self.unstable) }
        while true {
            await clock.sleep(for: Self.interval)
            guard !Task.isCancelled, let current = fileSystem.fileInfo(at: url) else { return .failure(Self.unstable) }
            if current.byteSize == previous.byteSize && current.modifiedAt == previous.modifiedAt {
                return .success(current)
            }
            if clock.now().timeIntervalSince(start) >= Self.limit { return .failure(Self.unstable) }
            previous = current
        }
    }

    static var unstable: FlotsamError { FlotsamError(.sspIo002, "Screenshot file did not settle or vanished") }
}
