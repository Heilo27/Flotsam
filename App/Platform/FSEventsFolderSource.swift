import CoreServices
import FlotsamBase
import Foundation

/// FRD-002 FR-002-04: the real `FolderEventSource`. One FSEvents stream per watch, file-level events, 0.3 s latency,
/// delivered on a private serial queue.
///
/// The stream is recursive by nature of FSEvents; "direct children only" is the consumer's rule (it drops
/// descendants), so this adapter reports every path it is given.
struct FSEventsFolderSource: FolderEventSource {
    static let latency: CFTimeInterval = 0.3

    func start(watching folder: URL, handler: @escaping @Sendable (FolderEvent) -> Void) -> FlotsamResult<any FolderWatch> {
        let watch = FSEventsWatch(handler: handler)
        guard watch.begin(folder: folder) else {
            return .failure(FlotsamError(.sspOs001, "Folder event stream could not be started"))
        }
        return .success(watch)
    }
}

/// Owns one stream. `stop()` invalidates it and, because events are delivered on `queue`, a callback already running
/// finishes before `stop()`'s barrier block does, so nothing is delivered after `stop()` returns.
private final class FSEventsWatch: FolderWatch, @unchecked Sendable {
    private let handler: @Sendable (FolderEvent) -> Void
    private let queue = DispatchQueue(label: "flotsam.screenshots.fsevents")
    private var stream: FSEventStreamRef?
    private var stopped = false

    init(handler: @escaping @Sendable (FolderEvent) -> Void) {
        self.handler = handler
    }

    func begin(folder: URL) -> Bool {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watch = Unmanaged<FSEventsWatch>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let flagsBuffer = UnsafeBufferPointer(start: eventFlags, count: count)
            watch.deliver(paths: list, flags: Array(flagsBuffer))
        }
        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [folder.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), FSEventsFolderSource.latency, flags)
        else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// Runs on `queue`.
    fileprivate func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard !stopped else { return }
        var changed: [URL] = []
        var rescan = false
        var invalid = false
        for (path, flag) in zip(paths, flags) {
            let flag = Int(flag)
            if flag & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                rescan = true
            }
            if flag & (kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount | kFSEventStreamEventFlagMount) != 0 {
                invalid = true
            }
            if flag & kFSEventStreamEventFlagItemIsFile != 0 { changed.append(URL(fileURLWithPath: path)) }
        }
        if invalid { handler(.invalidated); return }
        if rescan { handler(.rescan) }
        if !changed.isEmpty { handler(.changed(changed)) }
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
        }
    }

    deinit {
        // `stop()` is the contract; this is only a backstop so a dropped watch cannot leak a running stream.
        if let stream, !stopped {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
