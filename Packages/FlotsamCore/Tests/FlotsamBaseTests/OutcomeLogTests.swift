import Foundation
import os
import Testing
@testable import FlotsamBase

// FR-000-11 code-less outcome entries (`FlotsamLog.log(outcome:)`), observed through a recording sink. Expected
// values are literals.

@Suite struct OutcomeLogTests {
    /// given a migrate-complete outcome at info with a schema version and a row count, then the sink receives one
    /// record: storage category, `.info`, the dotted outcome name as headline, and both values in the clear.
    @Test("migrate complete logs info under storage with version and rows in the clear")
    func migrateCompleteInfo() {
        let sink = RecordingLogSink()
        FlotsamLog.log(
            outcome: .migrateComplete, category: .storage, level: .info,
            context: [.version: .int(3), .rows: .int(120)], sink: sink
        )
        #expect(sink.records.count == 1)
        let record = sink.records[0]
        #expect(record.category == .storage)
        #expect(record.level == .info)
        #expect(record.headline == "database.migrate.complete")
        #expect(record.publicContext == "rows=120 version=3")
        #expect(record.privateContext == "")
        #expect(record.publicText == "database.migrate.complete rows=120 version=3")
        #expect(record.message == nil)
        #expect(record.cause == nil)
    }

    /// given an integrity-check-ok outcome at debug with no context, then the level is `.debug`, the headline is the
    /// outcome name and there is no context.
    @Test("integrity check ok logs debug with no context")
    func integrityCheckDebug() {
        let sink = RecordingLogSink()
        FlotsamLog.log(outcome: .integrityCheckOk, category: .storage, level: .debug, sink: sink)
        #expect(sink.records == [LogRecord(
            category: .storage, level: .debug, headline: "database.integrityCheck.ok",
            publicContext: "", privateContext: "", message: nil, cause: nil
        )])
    }

    /// given no level argument, then the outcome is logged at `.info`.
    @Test("level defaults to info")
    func defaultLevel() {
        let sink = RecordingLogSink()
        FlotsamLog.log(outcome: .migrateComplete, category: .storage, sink: sink)
        #expect(sink.records.first?.level == .info)
    }

    /// given the same outcome under each category, then the record carries exactly the category passed.
    @Test("category is the one passed", arguments: LogCategory.allCases)
    func categoryPassedThrough(category: LogCategory) {
        let sink = RecordingLogSink()
        FlotsamLog.log(outcome: .integrityCheckOk, category: category, sink: sink)
        #expect(sink.records.first?.category == category)
    }

    /// given a context holding a non-allowlisted value (item id, bundle identifier), then it lands in `privateContext`
    /// and never in the clear, the same redaction an error context gets.
    @Test("non-allowlisted context values are private, as for an error")
    func redactionMatchesErrorPath() throws {
        let itemId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let bundle = try #require(BundleIdentifier("com.flotsamtest.outcomebid"))
        let context: [LogKey: LogSafeValue] = [
            .version: .int(2), .itemId: .id(itemId), .bundleId: .bundleId(bundle),
        ]
        let sink = RecordingLogSink()
        FlotsamLog.log(outcome: .migrateComplete, category: .storage, context: context, sink: sink)
        let errorRecord = FlotsamLog.record(for: FlotsamError(.stoDb001, "test", context: context))
        let record = sink.records[0]
        #expect(record.publicContext == "version=2")
        #expect(record.publicContext == errorRecord.publicContext)
        #expect(record.privateContext == errorRecord.privateContext)
        #expect(record.privateContext.contains("com.flotsamtest.outcomebid"))
        #expect(!record.publicText.contains("com.flotsamtest.outcomebid"))
        #expect(!record.publicText.contains("11111111-2222-3333-4444-555555555555"))
    }

    /// given the version key, then it renders as `version=<n>` and is public, so a release log shows it.
    @Test("LogKey.version is public-safe and renders as an integer")
    func versionKeyIsPublic() {
        #expect(LogKey.version.rawValue == "version")
        let rendered = FlotsamLog.render([.version: .int(7)])
        #expect(rendered.publicPart == "version=7")
        #expect(rendered.privatePart == "")
    }

    /// given the closed outcome list, then it is exactly these two dotted names; a new case is a deliberate change.
    @Test("the outcome list is closed")
    func outcomeListIsClosed() {
        #expect(OutcomeName.allCases.map(\.rawValue) == ["database.migrate.complete", "database.integrityCheck.ok"])
    }

    /// given an outcome and an event for the same database step, then both share the `database.migrate` prefix so one
    /// log search finds both.
    @Test("outcome names share the LogEvent database prefix")
    func prefixMatchesEvent() {
        #expect(OutcomeName.migrateComplete.rawValue.hasPrefix(LogEvent.database(.migrate, outcome: .migrated).name))
        #expect(OutcomeName.integrityCheckOk.rawValue.hasPrefix(LogEvent.database(.integrityCheck, outcome: .passed).name))
    }

    /// given the level type, then it has exactly the two non-alerting cases and they map to `.info` and `.debug`.
    @Test("OutcomeLevel maps to info and debug only")
    func levelMapping() {
        #expect(OutcomeLevel.info.osLogType == OSLogType.info)
        #expect(OutcomeLevel.debug.osLogType == OSLogType.debug)
    }
}
