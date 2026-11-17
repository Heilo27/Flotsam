import FlotsamBase
import Foundation

/// The fallback `FolderEventSource` (FRD-002 FR-002-04): no stream, one `rescan` every 5 s.
///
/// It reports nothing about which file changed. The watcher answers a `rescan` with its reconcile scan, which already
/// selects by the watermark and skips what was imported, so the poll needs no listing of its own.
public struct PollingFolderSource: FolderEventSource {
    public static let interval: Duration = .seconds(5)

    private let clock: any WallClock

    public init(clock: any WallClock) {
        self.clock = clock
    }

    public func start(watching folder: URL, handler: @escaping @Sendable (FolderEvent) -> Void) -> FlotsamResult<any FolderWatch> {
        let clock = clock
        let task = Task {
            while !Task.isCancelled {
                await clock.sleep(for: Self.interval)
                if Task.isCancelled { break }
                handler(.rescan)
            }
        }
        return .success(PollingWatch(task: task))
    }
}

private struct PollingWatch: FolderWatch {
    let task: Task<Void, Never>
    func stop() { task.cancel() }
}
