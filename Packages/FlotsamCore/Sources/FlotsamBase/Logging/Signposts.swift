import Foundation
import os

/// The seven measured intervals of FR-000-12. They are the PRD's p95 metrics, so the names are the contract that
/// Instruments lanes, other FRDs' performance targets and the scripted QA session all refer to.
public enum PerfInterval: String, CaseIterable, Sendable {
    case capturePersist = "capture.persist"
    case libraryOpen = "library.open"
    case librarySearch = "library.search"
    case pasteBack = "paste.back"
    case shelfReveal = "shelf.reveal"
    case retentionSweep = "retention.sweep"
    case triggerExpand = "trigger.expand"
}

/// An open interval; `end()` closes it. A value rather than a closure so async code can hold it across suspension
/// points without capturing anything.
public struct PerfSpan: Sendable {
    fileprivate let interval: PerfInterval
    fileprivate let state: OSSignpostIntervalState

    /// Closes the interval. Safe to call once; calling twice only produces a second end event for the same lane.
    public func end() {
        Signposts.end(self)
    }
}

/// `OSSignposter` wrapper, category `perf` (FR-000-12). Signposts carry no content: the only thing emitted is the
/// interval name, which is why `begin` takes an enum and offers no message or metadata parameter.
public enum Signposts {
    private static let signposter = OSSignposter(subsystem: FlotsamLog.subsystem, category: "perf")

    public static func begin(_ interval: PerfInterval) -> PerfSpan {
        // `beginInterval` needs a `StaticString` name, so the enum maps to literals here and nowhere else.
        let id = signposter.makeSignpostID()
        let state: OSSignpostIntervalState
        switch interval {
        case .capturePersist: state = signposter.beginInterval("capture.persist", id: id)
        case .libraryOpen: state = signposter.beginInterval("library.open", id: id)
        case .librarySearch: state = signposter.beginInterval("library.search", id: id)
        case .pasteBack: state = signposter.beginInterval("paste.back", id: id)
        case .shelfReveal: state = signposter.beginInterval("shelf.reveal", id: id)
        case .retentionSweep: state = signposter.beginInterval("retention.sweep", id: id)
        case .triggerExpand: state = signposter.beginInterval("trigger.expand", id: id)
        }
        return PerfSpan(interval: interval, state: state)
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
        }
    }

    /// Measures a synchronous operation. Prefer this to a manual begin/end pair so an early return cannot leave a
    /// lane open.
    public static func measure<Result>(_ interval: PerfInterval, _ body: () -> Result) -> Result {
        let span = begin(interval)
        defer { span.end() }
        return body()
    }
}
