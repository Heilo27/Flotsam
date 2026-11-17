import Foundation

/// What a folder watch reports (FRD-002 FR-002-04).
public enum FolderEvent: Sendable, Equatable {
    /// Paths that were created, renamed into place or modified. File-level, so a path may repeat across events and
    /// may name a descendant of the watched folder: the consumer applies the direct-children rule.
    case changed([URL])
    /// "Something may have changed, look at the whole folder": a polling tick, or a stream that lost events.
    case rescan
    /// The watch can no longer be trusted (the stream was reported invalid). The consumer replaces it.
    case invalidated
}

/// One running watch. Stopping is idempotent and no event is delivered after it returns.
public protocol FolderWatch: Sendable {
    func stop()
}

/// A way of being told about changes inside one folder (FRD-002 FR-002-04). FSEvents is the real adapter
/// (`App/Platform`), directory polling the fallback (FlotsamScreenshots); a test passes a fake.
public protocol FolderEventSource: Sendable {
    /// Starts watching `folder` (its direct children matter; the source may report more).
    /// Failure means the watch could not be created, which the caller treats as "this mechanism is unavailable".
    /// `handler` may be called from any thread and must not block.
    func start(watching folder: URL, handler: @escaping @Sendable (FolderEvent) -> Void) -> FlotsamResult<any FolderWatch>
}
