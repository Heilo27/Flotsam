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
    /// Seals concealed copies; nil rejects them (`CAP-POL-001`).
    var vault: (any SecureClipVaulting)? = nil
    /// Whether a copy of several files becomes one bundle (`capture.autoBundle`, FR-001-12). Read once per payload.
    var autoBundle: @Sendable () -> Bool = { true }

    /// Classifies and ingests `payload`. A failure is reported in the background unless `reportingFailure` is false
    /// (Save Clipboard shows it itself); it is returned either way, nil on success.
    @discardableResult
    func handle(_ payload: CapturedPayload, reportingFailure: Bool = true) async -> FlotsamError? {
        if payload.isConcealed { return await handleSecure(payload, reportingFailure: reportingFailure) }

        let classification: Classification
        switch CaptureClassifier.classify(payload.representations) {
        case .failure(let error):
            if reportingFailure { await reporter.report(error, origin: .background) }
            return error
        case .success(let value):
            classification = value
        }

        // FR-001-12: with auto-bundling off a multi-file copy is one item per file. A member's time is the copy's
        // minus its index in milliseconds, so Recent lists them in pasteboard order (as Ungroup does, FR-004-11).
        let parts = autoBundle() ? [classification] : CaptureClassifier.splitIntoMembers(classification)
        var firstFailure: FlotsamError?
        for (index, part) in parts.enumerated() {
            let candidate = IngestCandidate(
                classification: part, source: payload.source, origin: payload.origin,
                occurredAt: payload.capturedAt.addingTimeInterval(-Double(index) / 1000))
            if let failure = await ingestOne(candidate, payload: payload, reportingFailure: reportingFailure) {
                firstFailure = firstFailure ?? failure
            }
        }
        return firstFailure
    }

    private func ingestOne(_ candidate: IngestCandidate, payload: CapturedPayload, reportingFailure: Bool) async -> FlotsamError? {
        switch await ingest.ingest(candidate) {
        case .failure(let error):
            // FR-001-22: this item is lost, the pipeline carries on with the next.
            let failure = Self.captureFailure(error)
            if reportingFailure { await reporter.report(failure, origin: .background) }
            return failure
        case .success(let result):
            for warning in result.warnings { await reporter.report(warning, origin: .background) }
            FlotsamLog.log(
                .pasteboardProcessed(
                    kind: candidate.kind, byteSize: payload.representations.reduce(0) { $0 + $1.data.count },
                    outcome: result.outcome.isBump ? .deduped : .stored, policy: nil),
                sink: sink)
            return nil
        }
    }
}

extension IngestWorker {
    /// A concealed copy (FR-001-04 gate 3): seal the plain text and ingest only the ciphertext. Whatever goes wrong
    /// before there is a ciphertext (no vault, no usable text, no usable key) is a policy rejection, `CAP-POL-001`:
    /// logged as a skip, never raised, and nothing is stored. The text itself is never logged, never in an error, and
    /// the log line carries 0 bytes (the length of a password is not for the log either).
    private func handleSecure(_ payload: CapturedPayload, reportingFailure: Bool) async -> FlotsamError? {
        let rejection = FlotsamError(.capPol001, "Concealed copy was not stored")
        let text = payload.representations.first { $0.uti == PasteboardTypes.plainText }
            .map { String(decoding: $0.data, as: UTF8.self) }
        guard let vault, let text, !text.allSatisfy(\.isWhitespace) else {
            logSkip()
            return rejection
        }
        let sealed: SealedSecret
        switch vault.seal(text) {
        case .failure:
            logSkip()
            return rejection
        case .success(let value):
            sealed = value
        }

        let candidate = IngestCandidate(
            secure: sealed, source: payload.source, origin: payload.origin, occurredAt: payload.capturedAt)
        switch await ingest.ingest(candidate) {
        case .failure(let error):
            let failure = Self.captureFailure(error)
            if reportingFailure { await reporter.report(failure, origin: .background) }
            return failure
        case .success(let result):
            for warning in result.warnings { await reporter.report(warning, origin: .background) }
            FlotsamLog.log(
                .pasteboardProcessed(
                    kind: .text, byteSize: 0, outcome: result.outcome.isBump ? .deduped : .stored, policy: nil),
                sink: sink)
            return nil
        }
    }

    private func logSkip() {
        FlotsamLog.log(.pasteboardProcessed(kind: nil, byteSize: 0, outcome: .skipped, policy: .capPol001), sink: sink)
    }

    /// A write the disk or database refused (`STO-DB-001`, `STO-IO-001`) is, for capture, a copy that could not be
    /// saved: `CAP-IO-001` (FR-001-22), keeping the cause: the underlying error when there is one, and always the
    /// original `STO-*` code as the `code` context field (a refusal from DiskGuard or BlobStore has no underlying
    /// error, so the code is then the only trace of which write failed). Every other pipeline failure keeps its own code.
    static func captureFailure(_ error: FlotsamError) -> FlotsamError {
        switch error.code {
        case .stoDb001, .stoIo001:
            FlotsamError(
                .capIo001, "Capture write refused", context: error.context.merging([.code: .code(error.code)]) { _, new in new },
                underlying: error.underlying)
        default:
            error
        }
    }
}

private extension IngestOutcome {
    var isBump: Bool { if case .bumped = self { true } else { false } }
}
