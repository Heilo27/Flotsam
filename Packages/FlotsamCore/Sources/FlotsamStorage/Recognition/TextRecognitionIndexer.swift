import FlotsamBase
import Foundation

/// Reads the text in stored images and screenshots so search can find them (FRD-007 FR-007-23, FRD-003 FR-003-55).
///
/// Work only, never a clock (S5, ADR-0004 amendment TASK-552): there is no timer and no poll. A pass runs when the app
/// starts and when `itemsChanged` says an item arrived, takes the newest `batchSize` images that have never been read,
/// reads them one at a time at background priority, and stops. Whatever is left (a large library on its first launch
/// with the feature) waits for the next launch or the next ingest, so the backfill is bounded per trigger and never
/// becomes a long-running loop. An image that fails, or holds no text, is recorded as attempted and not retried.
///
/// Caller contract: `start()` is called once the database is open. Nothing here publishes an event: writing text is
/// invisible to the Library until its next query, and publishing `itemsChanged` would re-trigger this very indexer.
public actor TextRecognitionIndexer {
    /// Images read per pass. Small on purpose: each is a full decode plus a Vision request.
    static let batchSize = 12

    private let database: FlotsamDatabase
    private let recognizer: any TextRecognitionPort
    private var unsubscribe: (@Sendable () -> Void)?
    private var running = false
    private var again = false
    private var stopped = false

    public init(database: FlotsamDatabase, recognizer: any TextRecognitionPort) {
        self.database = database
        self.recognizer = recognizer
    }

    /// Idempotent. Subscribes to ingest and queues the launch pass; both run at background priority.
    public func start() {
        guard unsubscribe == nil else { return }
        stopped = false
        unsubscribe = database.events.subscribe { [weak self] event in
            guard case .itemsChanged = event else { return }
            Task(priority: .background) { await self?.runPass() }
        }
        Task(priority: .background) { [weak self] in await self?.runPass() }
    }

    public func stop() {
        stopped = true
        unsubscribe?()
        unsubscribe = nil
    }

    /// One pass now. A pass already running is not doubled up: the request is remembered and one more batch follows it,
    /// so an item ingested mid-pass is still picked up.
    public func runPass() async {
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            await processBatch()
        } while again && !stopped
    }

    private func processBatch() async {
        let candidates: [FlotsamDatabase.RecognitionCandidate]
        switch await database.itemsAwaitingRecognition(limit: Self.batchSize) {
        case .failure(let error):
            database.report(error)
            return
        case .success(let value): candidates = value
        }
        for candidate in candidates {
            if stopped { return }
            await recognize(candidate)
        }
    }

    private func recognize(_ candidate: FlotsamDatabase.RecognitionCandidate) async {
        var text: String?
        switch database.recognitionSource(candidate) {
        case .failure(let error): database.report(error)
        case .success(let data):
            switch await recognizer.recognizeText(in: data) {
            case .success(let recognized): text = recognized
            case .failure(let error): database.report(error)
            }
        }
        // Recorded even when nothing was read, so a bad or text-free image is not queued again. A failed write is
        // reported and the item stays queued for the next pass.
        if case .failure(let error) = await database.storeRecognizedText(text, itemId: candidate.itemId) {
            database.report(error)
        }
    }
}
