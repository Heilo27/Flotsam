import Foundation
import Testing
@testable import FlotsamBase

// TASK-432 blind QA, FR-000-11 "permission changed": a baseline read logs nothing; only a flip logs, once, with the
// permission's name and the new state.

private final class FlippableProbe: PermissionProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: [PermissionKind: Bool]
    init(_ initial: [PermissionKind: Bool]) { granted = initial }
    func set(_ kind: PermissionKind, _ value: Bool) { lock.withLock { granted[kind] = value } }
    func isGranted(_ kind: PermissionKind) -> Bool { lock.withLock { granted[kind] ?? false } }
    func request(_ kind: PermissionKind) {}
    func openSystemSettings(_ kind: PermissionKind) {}
}

private final class CollectingSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [LogRecord] = []
    var records: [LogRecord] { lock.withLock { all } }
    func write(_ record: LogRecord) { lock.withLock { all.append(record) } }
}

@MainActor
@Suite struct Worf432bPermissionTests {
    /// OC-432-20. Given the first read (granted and denied), when check() runs, then nothing is logged. Red if the
    /// baseline is logged as a change (the user would see a transition at every launch).
    @Test func oc43220_baselineLogsNothing() {
        let probe = FlippableProbe([.accessibility: true, .inputMonitoring: false])
        let sink = CollectingSink()
        let logger = PermissionTransitionLogger(probe: probe, sink: sink)

        logger.check()

        #expect(sink.records.isEmpty)
    }

    /// OC-432-21. Given a baseline, when accessibility is revoked, then exactly one line `permission.changed` naming
    /// accessibility and outcome=denied at .info; a second check with no change adds
    /// none; regranting adds one granted=true. Red if the sink is not called, the wrong permission is named, the
    /// state is inverted, or unchanged reads re-log.
    @Test func oc43221_flipLogsOnceWithNameAndNewState() {
        let probe = FlippableProbe([.accessibility: true, .inputMonitoring: false])
        let sink = CollectingSink()
        let logger = PermissionTransitionLogger(probe: probe, sink: sink)
        logger.check()

        probe.set(.accessibility, false)
        logger.check()
        logger.check()
        probe.set(.accessibility, true)
        logger.check()

        #expect(sink.records.map(\.headline) == ["permission.changed", "permission.changed"])
        #expect(sink.records.map(\.publicContext) == ["outcome=denied permission=accessibility", "outcome=granted permission=accessibility"])
        #expect(sink.records.allSatisfy { $0.level == .info })
    }

    /// OC-432-22. Given both permissions flip in one check, when check() runs, then one line per permission, each with
    /// its own name (input monitoring is not reported as accessibility).
    @Test func oc43222_bothFlipsAreReportedSeparately() {
        let probe = FlippableProbe([.accessibility: false, .inputMonitoring: false])
        let sink = CollectingSink()
        let logger = PermissionTransitionLogger(probe: probe, sink: sink)
        logger.check()

        probe.set(.accessibility, true)
        probe.set(.inputMonitoring, true)
        logger.check()

        #expect(Set(sink.records.map(\.publicContext)) == ["outcome=granted permission=accessibility", "outcome=granted permission=inputMonitoring"])
        #expect(sink.records.count == 2)
    }
}
