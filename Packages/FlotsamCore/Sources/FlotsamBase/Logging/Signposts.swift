import Foundation
import os

/// The nine measured intervals of FR-000-12. They are the PRD's p95 metrics, so the names are the contract that
/// Instruments lanes, other FRDs' performance targets and the scripted QA session all refer to.
public enum PerfInterval: String, CaseIterable, Sendable {
    case capturePersist = "capture.persist"
    case libraryOpen = "library.open"
    case librarySearch = "library.search"
    case pasteBack = "paste.back"
    case shelfReveal = "shelf.reveal"
    case retentionSweep = "retention.sweep"
    case triggerExpand = "trigger.expand"
    /// One interval for the whole Clear History operation: count, every delete batch and the scrub (FRD-007 FR-007-16).
    case retentionClearHistory = "retention.clearHistory"
    /// One screenshot pickup from the stability check to the ingest result, whatever the outcome (FRD-002 FR-002-14).
    case screenshotImport = "screenshot.import"
}

/// A point-in-time event inside an open interval. Names are fixed, like the intervals, so an event carries no content.
public enum PerfEvent: Sendable {
    /// One delete batch inside the `retention.sweep` interval (FRD-007 FR-007-09).
    case retentionSweepBatch
}

/// One begin or end of a scoped interval, as `Signposts.observe(scope:)` delivers it (TASK-510 test seam).
struct ScopedSignpostEdge: Sendable {
    enum Kind: Sendable { case begin, end }
    let kind: Kind
    let interval: PerfInterval
    let scope: UInt32
    /// Pairs a begin with its end, like the signpost id's low 32 bits.
    let serial: UInt32
}

/// An open interval; `end()` closes it. A value rather than a closure so async code can hold it across suspension
/// points without capturing anything.
public struct PerfSpan: Sendable {
    fileprivate let interval: PerfInterval
    fileprivate let state: OSSignpostIntervalState
    /// Nonzero only for an interval a test opened under a scope (`Signposts.begin(_:scope:)`); 0 in production.
    fileprivate let scope: UInt32
    fileprivate let serial: UInt32

    /// Closes the interval. Safe to call once; calling twice only produces a second end event for the same lane.
    public func end() {
        Signposts.end(self)
    }
}

/// `OSSignposter` wrapper, category `perf` (FR-000-12). Signposts carry no content: the only thing emitted is the
/// interval name, which is why `begin` takes an enum and offers no message or metadata parameter.
public enum Signposts {
    private static let signposter = OSSignposter(subsystem: FlotsamLog.subsystem, category: "perf")
    private static let scopedCounter = OSAllocatedUnfairLock(initialState: UInt32(0))

    /// The id of one interval. Unscoped (production, `scope` 0) is a system-made id. A scope is a number a test picks so
    /// the intervals it opens are told apart from every other test's in the same process: the id's high 32 bits are the
    /// scope and the low 32 a counter, so `id >> 32 == scope` picks them out of the signpost stream. Not content: the
    /// stream still carries only the interval name and an id.
    private static func makeID(scope: UInt32) -> (id: OSSignpostID, scope: UInt32, serial: UInt32) {
        guard scope != 0 else { return (signposter.makeSignpostID(), 0, 0) }
        let serial = scopedCounter.withLock { value -> UInt32 in
            value &+= 1
            return value
        }
        let masked = scope & 0x7FFF_FFFF
        return (OSSignpostID((UInt64(masked) << 32) | UInt64(serial)), masked, serial)
    }

    // The unified-log signpost stream a test reads (`log stream`) is lossy under host load: with a few thousand
    // signposts from the other suites of the process in flight, one begin of an overlapping pair never arrived while its
    // end did (TASK-510, 3 of 17 runs under 200 busy processes). A test that must count intervals exactly therefore
    // watches them here, in-process, where nothing is dropped. Only a scoped interval is reported, so production (scope 0)
    // pays nothing.
    private static let observers = OSAllocatedUnfairLock(initialState: [UInt32: @Sendable (ScopedSignpostEdge) -> Void]())

    /// Reports every interval opened under `scope` (begin and end, synchronously on the calling thread) to `handler`.
    static func observe(scope: UInt32, _ handler: @escaping @Sendable (ScopedSignpostEdge) -> Void) {
        observers.withLock { $0[scope & 0x7FFF_FFFF] = handler }
    }

    static func stopObserving(scope: UInt32) {
        _ = observers.withLock { $0.removeValue(forKey: scope & 0x7FFF_FFFF) }
    }

    private static func notify(_ kind: ScopedSignpostEdge.Kind, _ interval: PerfInterval, scope: UInt32, serial: UInt32) {
        guard scope != 0, let handler = observers.withLock({ $0[scope] }) else { return }
        handler(ScopedSignpostEdge(kind: kind, interval: interval, scope: scope, serial: serial))
    }

    /// `scope` is for tests only (see `makeID`); every production call leaves it 0.
    public static func begin(_ interval: PerfInterval, scope: UInt32 = 0) -> PerfSpan {
        // `beginInterval` needs a `StaticString` name, so the enum maps to literals here and nowhere else.
        let made = makeID(scope: scope)
        let id = made.id
        let state: OSSignpostIntervalState
        switch interval {
        case .capturePersist: state = signposter.beginInterval("capture.persist", id: id)
        case .libraryOpen: state = signposter.beginInterval("library.open", id: id)
        case .librarySearch: state = signposter.beginInterval("library.search", id: id)
        case .pasteBack: state = signposter.beginInterval("paste.back", id: id)
        case .shelfReveal: state = signposter.beginInterval("shelf.reveal", id: id)
        case .retentionSweep: state = signposter.beginInterval("retention.sweep", id: id)
        case .triggerExpand: state = signposter.beginInterval("trigger.expand", id: id)
        case .retentionClearHistory: state = signposter.beginInterval("retention.clearHistory", id: id)
        case .screenshotImport: state = signposter.beginInterval("screenshot.import", id: id)
        }
        notify(.begin, interval, scope: made.scope, serial: made.serial)
        return PerfSpan(interval: interval, state: state, scope: made.scope, serial: made.serial)
    }

    fileprivate static func end(_ span: PerfSpan) {
        switch span.interval {
        case .capturePersist: signposter.endInterval("capture.persist", span.state)
        case .libraryOpen: signposter.endInterval("library.open", span.state)
        case .librarySearch: signposter.endInterval("library.search", span.state)
        case .pasteBack: signposter.endInterval("paste.back", span.state)
        case .shelfReveal: signposter.endInterval("shelf.reveal", span.state)
        case .retentionSweep: signposter.endInterval("retention.sweep", span.state)
        case .triggerExpand: signposter.endInterval("trigger.expand", span.state)
        case .retentionClearHistory: signposter.endInterval("retention.clearHistory", span.state)
        case .screenshotImport: signposter.endInterval("screenshot.import", span.state)
        }
        notify(.end, span.interval, scope: span.scope, serial: span.serial)
    }

    /// Measures a synchronous operation. Prefer this to a manual begin/end pair so an early return cannot leave a
    /// lane open.
    public static func measure<Result>(_ interval: PerfInterval, scope: UInt32 = 0, _ body: () -> Result) -> Result {
        let span = begin(interval, scope: scope)
        defer { span.end() }
        return body()
    }

    /// Async form for the actor-hosted paths (ingest, sweep, Clear History). The result is `Sendable` because it
    /// crosses the `@concurrent` boundary of the closure.
    public static func measure<Result: Sendable>(_ interval: PerfInterval, _ body: () async -> Result) async -> Result {
        let span = begin(interval)
        defer { span.end() }
        return await body()
    }

    /// Emits a named event inside whatever interval is open.
    public static func event(_ event: PerfEvent) {
        switch event {
        case .retentionSweepBatch: signposter.emitEvent("retention.sweep.batch")
        }
    }
}
