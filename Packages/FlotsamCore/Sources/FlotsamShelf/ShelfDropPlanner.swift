import FlotsamBase
import FlotsamPayload
import FlotsamStorage
import Foundation

/// Whether the Shelf takes a hovering or dropped drag (FR-006-12).
public enum ShelfDropAcceptance: Sendable, Equatable {
    /// Highlight the drop zone and show the copy badge.
    case accepted
    /// No highlight, not-allowed cursor; a drop shows `SHF-VAL-001` (FR-006-14).
    case refused
    /// The drag started in the Shelf itself: refused like `refused`, but a drop shows nothing at all (FR-006-12).
    case refusedSilently
}

/// What a dropped pasteboard becomes: the one candidate for the ingest pipeline, and the dropped files that could not
/// be read (each is an `SHF-IO-001`, FR-006-14).
public struct ShelfDropPlan: Sendable, Equatable {
    public let candidate: IngestCandidate
    public let skipped: [FlotsamError]
}

/// Decides whether a drop is accepted and what it stores (FR-006-12 to FR-006-14). Pure apart from asking whether a
/// dropped file is readable: no AppKit, no pasteboard, no database. The Shelf never decides classification itself; it
/// calls `CaptureClassifier`, so a drop is processed as if it had been a pasteboard change (FR-006-13).
public enum ShelfDropPlanner {
    /// Type identifiers only, no data (FR-006-12, BR-4): accepted when at least one honoured type (FRD-001 FR-001-05)
    /// is present and none of the marker types of FRD-001 FR-001-04 gate 3 is. A drag that began in the Shelf is
    /// refused whatever it carries.
    public static func acceptance(types: [String], originatesInShelf: Bool) -> ShelfDropAcceptance {
        if originatesInShelf { return .refusedSilently }
        return acceptsTypes(types) ? .accepted : .refused
    }

    /// - Parameters:
    ///   - types: every type identifier the drag pasteboard declares (markers included).
    ///   - representations: the bytes of the honoured types, read once the drop is accepted
    ///     (`PasteboardTypes.typesToRead(from:)`), as clipboard capture reads them.
    ///   - isReadable: whether a dropped file or folder can be read; the file system is the only thing this asks.
    /// - Returns: the plan; `SHF-VAL-001` when the types are not accepted or nothing storable is left; `SHF-IO-001`
    ///   when files were dropped and none of them can be read.
    public static func plan(
        types: [String], representations: [PasteboardRepresentation], source: SourceApp?, occurredAt: Date,
        isReadable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
    ) -> FlotsamResult<ShelfDropPlan> {
        guard acceptsTypes(types) else {
            return .failure(FlotsamError(.shfVal001, "Drop carries no storable type or a never-store marker"))
        }

        var classifiable = representations
        var skipped: [FlotsamError] = []
        let droppedFiles = representations.filter { $0.uti == PasteboardTypes.fileURL }
        if !droppedFiles.isEmpty {
            // The classifier would drop an unreadable file without a word; the Shelf must name each one (FR-006-14).
            let readable = droppedFiles.filter { entry in
                guard let url = PasteboardTypes.fileURL(from: entry.data), isReadable(url.standardizedFileURL.path) else {
                    skipped.append(FlotsamError(.shfIo001, "Dropped file cannot be read or is gone"))
                    return false
                }
                return true
            }
            guard !readable.isEmpty else {
                return .failure(FlotsamError(
                    .shfIo001, "No dropped file can be read", context: [.count: .int(droppedFiles.count)]))
            }
            classifiable = readable
        }

        switch CaptureClassifier.classify(classifiable) {
        case .failure(let error):
            return .failure(mapped(error, droppedFileCount: droppedFiles.count))
        case .success(let classification):
            let candidate = IngestCandidate(
                classification: classification, source: source, origin: .shelfDrop, occurredAt: occurredAt)
            return .success(ShelfDropPlan(candidate: candidate, skipped: skipped))
        }
    }

    private static func acceptsTypes(_ types: [String]) -> Bool {
        PasteboardTypes.hasHonoured(in: types) && !types.contains(where: PasteboardMarkers.neverStore.contains)
    }

    /// The classifier speaks in capture codes; a drop's failures are the Shelf's own (FR-006-14).
    private static func mapped(_ error: FlotsamError, droppedFileCount: Int) -> FlotsamError {
        switch error.code {
        case .capVal001:
            FlotsamError(.shfVal001, "Drop holds nothing storable")
        case .capDat001:
            FlotsamError(.shfIo001, "Dropped files are gone", context: [.count: .int(droppedFileCount)])
        default:
            error
        }
    }
}
