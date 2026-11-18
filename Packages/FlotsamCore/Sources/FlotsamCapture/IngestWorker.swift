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

    func handle(_ payload: CapturedPayload) async {
        let classification: Classification
        switch CaptureClassifier.classify(payload.representations) {
        case .failure(let error):
            return await reporter.report(error, origin: .background)
        case .success(let value):
            classification = value
        }

        let candidate = IngestCandidate(
            classification: classification, source: payload.source, origin: payload.origin,
            occurredAt: payload.capturedAt)

        switch await ingest.ingest(candidate) {
        case .failure(let error):
            // FR-001-22: this item is lost, the pipeline carries on with the next.
            await reporter.report(Self.captureFailure(error), origin: .background)
        case .success(let result):
            for warning in result.warnings { await reporter.report(warning, origin: .background) }
            FlotsamLog.log(
                .pasteboardProcessed(
                    kind: classification.kind, byteSize: payload.representations.reduce(0) { $0 + $1.data.count },
                    outcome: result.outcome.isBump ? .deduped : .stored, policy: nil),
                sink: sink)
        }
    }
}

extension IngestWorker {
    /// A write the disk or database refused (`STO-DB-001`, `STO-IO-001`) is, for capture, a copy that could not be
    /// saved: `CAP-IO-001` (FR-001-22), keeping the cause. Every other pipeline failure keeps its own code.
    static func captureFailure(_ error: FlotsamError) -> FlotsamError {
        switch error.code {
        case .stoDb001, .stoIo001:
            FlotsamError(.capIo001, "Capture write refused", context: error.context, underlying: error.underlying)
        default:
            error
        }
    }
}

private extension IngestOutcome {
    var isBump: Bool { if case .bumped = self { true } else { false } }
}
