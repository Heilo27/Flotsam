import FlotsamBase
import FlotsamPayload
import FlotsamStorage
import Foundation

/// The ingest pipeline as the watcher needs it (FRD-007 FR-007-05). A port so the watcher's tests can record what
/// would have been stored without a database; `IngestActor` is the real conformance.
public protocol ScreenshotIngesting: Sendable {
    func ingest(_ candidate: IngestCandidate) async -> FlotsamResult<IngestResult>
}

extension IngestActor: ScreenshotIngesting {}

/// `meta.screenshots.lastScanAt` as the watcher reads and writes it (FRD-002 FR-002-08).
public protocol ScreenshotWatermarkStore: Sendable {
    func lastScanAt() async -> FlotsamResult<Date?>
    func setLastScanAt(_ date: Date) async -> FlotsamResult<Void>
}

/// The real watermark store: the database's `meta` table.
public struct DatabaseWatermarkStore: ScreenshotWatermarkStore {
    private let database: FlotsamDatabase

    public init(database: FlotsamDatabase) {
        self.database = database
    }

    public func lastScanAt() async -> FlotsamResult<Date?> { await database.screenshotsLastScanAt() }
    public func setLastScanAt(_ date: Date) async -> FlotsamResult<Void> { await database.setScreenshotsLastScanAt(date) }
}

/// What importing one file came to.
enum ScreenshotImportAttempt: Sendable {
    case imported(IngestResult, byteSize: Int)
    /// `SSP-IO-002`: vanished, unreadable or never settled. The caller puts live files on the retry list.
    case unstable(FlotsamError)
    /// `SSP-VAL-001` / `SSP-LIM-001`: the file will never import, so it is not retried (FR-002-13).
    case rejected(FlotsamError, byteSize: Int)
    case failed(FlotsamError, byteSize: Int)
}

/// FR-002-09: stability check, one read of the bytes, then the ingest pipeline. The original file is only read.
struct ScreenshotImporter: Sendable {
    /// FR-002-09: the catalogue label's bundle identifier; the label itself is `ui.source.screenshot`.
    static let sourceBundleId = "com.apple.screencaptureui"
    static let sourceLabelKey = "ui.source.screenshot"

    let fileSystem: any FileSystemPort
    let stability: StabilityCheck
    let ingest: any ScreenshotIngesting

    /// Off the caller's executor: the read and the 0.5 s waits must not hold the watcher actor.
    @concurrent
    func run(_ file: ScreenshotFile, countsAsCopy: Bool) async -> ScreenshotImportAttempt {
        // FR-000-12 / FR-002-14: one interval per pickup; `defer` closes it on every return below, failures included.
        let span = Signposts.begin(.screenshotImport)
        defer { span.end() }
        let info: FileInfo
        switch await stability.waitUntilStable(file.url) {
        case .failure(let error): return .unstable(error)
        case .success(let value): info = value
        }
        // FR-002-16: never read through a link, and never read a file that resolves outside the watched folder. `info`
        // may be stale by now, so the read below refuses a link itself instead of trusting this check alone.
        guard ScreenshotPathGuard.accepts(file.url, kind: info.kind, in: file.folder) else {
            return .rejected(FlotsamError(.sspVal001, "Not a regular file inside the screenshot folder"), byteSize: 0)
        }
        let bytes: Data
        switch fileSystem.readFileNoFollow(at: file.url) {
        case .failure(let error) where error.isLinkOrNotRegularFile:
            return .rejected(FlotsamError(.sspVal001, "Swapped for a link or a non-regular file before the read"), byteSize: 0)
        case .failure: return .unstable(StabilityCheck.unstable)
        case .success(let data): bytes = data
        }
        // The date is re-derived from the settled file: a file that was still being written reports its final dates.
        let settled = ScreenshotFile(url: file.url, folder: file.folder, info: info)
        let candidate = IngestCandidate(
            kind: .screenshot,
            contentKey: ContentKey.image(bytes),
            representations: [PasteboardRepresentation(uti: Self.uti(forFileNamed: file.url.lastPathComponent), data: bytes)],
            source: SourceApp(bundleId: Self.sourceBundleId, name: FlotsamStrings.text(forKey: Self.sourceLabelKey)),
            origin: .screenshotFile,
            occurredAt: settled.createdAt,
            originalPath: file.url.path,
            countsAsCopy: countsAsCopy)
        switch await ingest.ingest(candidate) {
        case .success(let result): return .imported(result, byteSize: bytes.count)
        case .failure(let error) where error.code == .sspVal001 || error.code == .sspLim001:
            return .rejected(error, byteSize: bytes.count)
        case .failure(let error): return .failed(error, byteSize: bytes.count)
        }
    }

    /// The type the extension implies; the image pipeline re-derives the real one from the bytes (FR-007-07).
    static func uti(forFileNamed name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": "public.png"
        case "jpg", "jpeg": "public.jpeg"
        case "tiff", "tif": "public.tiff"
        case "heic": "public.heic"
        default: "public.image"
        }
    }
}
