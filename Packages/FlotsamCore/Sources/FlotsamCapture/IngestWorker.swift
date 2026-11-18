import FlotsamBase
import FlotsamPayload
import FlotsamStorage
import Foundation

/// The off-main half of capture (FR-001-17): classifies a `CapturedPayload`, then hands the result to the ingest
/// actor. Hashing, markup conversion and bookmark creation all happen here, never on the main actor.
struct IngestWorker: Sendable {
    let ingest: IngestActor
    let reporter: ErrorReporter
    let sink: any LogSink

    /// Classifies and ingests `payload`. A failure is reported in the background unless `reportingFailure` is false
    /// (Save Clipboard shows it itself); it is returned either way, nil on success.
    @discardableResult
    func handle(_ payload: CapturedPayload, reportingFailure: Bool = true) async -> FlotsamError? {
        let classification: Classification
        switch CaptureClassifier.classify(payload.representations) {
        case .failure(let error):
            if reportingFailure { await reporter.report(error, origin: .background) }
            return error
        case .success(let value):
            classification = value
        }

        let candidate = IngestCandidate(
            classification: classification, source: payload.source, origin: payload.origin,
            occurredAt: payload.capturedAt)

        switch await ingest.ingest(candidate) {
        case .failure(let error):
            // FR-001-22: this item is lost, the pipeline carries on with the next.
            if reportingFailure { await reporter.report(error, origin: .background) }
            return error
        case .success(let result):
            for warning in result.warnings { await reporter.report(warning, origin: .background) }
            FlotsamLog.log(
                .pasteboardProcessed(
                    kind: classification.kind, byteSize: payload.representations.reduce(0) { $0 + $1.data.count },
                    outcome: result.outcome.isBump ? .deduped : .stored, policy: nil),
                sink: sink)
            return nil
        }
    }
}

private extension IngestOutcome {
    var isBump: Bool { if case .bumped = self { true } else { false } }
}
