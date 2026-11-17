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
            kind: classification.kind, contentKey: classification.contentKey, plainText: classification.plainText,
            representations: classification.representations,
            members: classification.members.map {
                IngestMember(path: $0.path, bookmark: $0.bookmark, isDirectory: $0.isDirectory)
            },
            source: payload.source, origin: payload.origin, occurredAt: payload.capturedAt)

        // Classifier warnings (a trimmed bundle) are reported whether or not ingest succeeds.
        for warning in classification.warnings { await reporter.report(warning, origin: .background) }

        switch await ingest.ingest(candidate) {
        case .failure(let error):
            // FR-001-22: this item is lost, the pipeline carries on with the next.
            await reporter.report(error, origin: .background)
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

private extension IngestOutcome {
    var isBump: Bool { if case .bumped = self { true } else { false } }
}
