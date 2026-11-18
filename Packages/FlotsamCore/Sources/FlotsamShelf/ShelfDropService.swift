import FlotsamBase
import FlotsamPayload
import FlotsamStorage
import Foundation

/// What a drop came to.
public enum ShelfDropResult: Sendable, Equatable {
    /// The drag began in the Shelf: nothing happened and nothing was shown (FR-006-12).
    case ignored
    /// Nothing was stored. The error has been reported.
    case failed(FlotsamError)
    /// The item to highlight and scroll to (FR-006-15), and how many dropped files were skipped as unreadable.
    case stored(itemId: UUID, skippedFiles: Int)
}

/// Carries a drop from the drag pasteboard to storage (FR-006-13, FR-006-14, FR-006-18). The app reads the pasteboard
/// (types, then bytes once accepted) and calls `drop`; everything after that is here, so it is tested without AppKit.
public struct ShelfDropService: Sendable {
    private let ingest: any ShelfIngesting
    private let reporter: ErrorReporter
    private let sink: any LogSink
    private let isReadable: @Sendable (String) -> Bool
    private let dropCompleted: @Sendable () async -> Void

    /// - Parameter dropCompleted: called once for a drop that stored or bumped an item, so the reveal machine can
    ///   hold a transient Shelf open (`ShelfRevealMachine.Event.dropCompleted`, FR-006-15).
    public init(
        ingest: any ShelfIngesting, reporter: ErrorReporter, sink: any LogSink = OSLogSink(),
        isReadable: @escaping @Sendable (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) },
        dropCompleted: @escaping @Sendable () async -> Void
    ) {
        self.ingest = ingest
        self.reporter = reporter
        self.sink = sink
        self.isReadable = isReadable
        self.dropCompleted = dropCompleted
    }

    public func drop(
        types: [String], representations: [PasteboardRepresentation], source: SourceApp?, originatesInShelf: Bool,
        occurredAt: Date
    ) async -> ShelfDropResult {
        if ShelfDropPlanner.acceptance(types: types, originatesInShelf: originatesInShelf) == .refusedSilently {
            return .ignored
        }

        let plan: ShelfDropPlan
        switch ShelfDropPlanner.plan(
            types: types, representations: representations, source: source, occurredAt: occurredAt,
            isReadable: isReadable)
        {
        case .failure(let error):
            return await fail(error)
        case .success(let value):
            plan = value
        }

        // Skipped files are reported whether or not the rest is stored; the reporter's throttle spaces the HUDs.
        for error in plan.skipped { await reporter.report(error, origin: .userInitiated) }

        switch await ingest.ingest(plan.candidate) {
        case .failure(let error):
            return await fail(ShelfDropPlanner.ingestFailure(error))
        case .success(let result):
            // Stored with a trimmed bundle or dropped rich text: not a failure of the drop (FR-007-06).
            for warning in result.warnings { await reporter.report(warning, origin: .background) }
            FlotsamLog.log(
                .shelf(.dropIn, outcome: plan.skipped.isEmpty ? .droppedIn : .stored,
                    detail: plan.skipped.first.map { .code($0.code) } ?? .none),
                sink: sink)
            await dropCompleted()
            return .stored(itemId: result.outcome.itemId, skippedFiles: plan.skipped.count)
        }
    }

    private func fail(_ error: FlotsamError) async -> ShelfDropResult {
        await reporter.report(error, origin: .userInitiated)
        FlotsamLog.log(.shelf(.dropIn, outcome: .failed, detail: .code(error.code)), sink: sink)
        return .failed(error)
    }
}

private extension IngestOutcome {
    var itemId: UUID {
        switch self {
        case .created(let id), .bumped(let id), .unchanged(let id): id
        }
    }
}
