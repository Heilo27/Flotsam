import FlotsamBase
import Foundation

/// Ingest limits (FRD-007 FR-007-06). The one home; Payload and Capture read these, never restate them (ADR-0009).
public enum IngestLimits {
    public static let maxTextBytes = 10 * 1024 * 1024
    public static let maxRichRepresentationBytes = 5 * 1024 * 1024
    public static let maxImageBytes = 100 * 1024 * 1024
    public static let maxBundleMembers = 500
    public static let maxNoteCharacters = 2000

    /// The note counter appears from here (FR-004-06): 90% of the ceiling.
    public static let noteCounterThreshold = maxNoteCharacters / 10 * 9

    /// A note's length in the unit the ceiling is stated in: Unicode scalars, which is what the schema's own
    /// `CHECK (length(note) <= 2000)` counts. The one counting rule: `setNote` and the note counter both call this, so
    /// the counter can never show a note as fine that save rejects (a ZWJ emoji is one Character but several scalars).
    public static func noteLength(_ note: String) -> Int { note.unicodeScalars.count }
}

/// What FR-007-06 leaves of a candidate once the ceilings are applied.
struct LimitedPayload: Sendable {
    let representations: [PasteboardRepresentation]
    let members: [IngestMember]
    let warnings: [FlotsamError]
}

extension IngestLimits {
    /// Rich-text representations, the only ones that may be dropped alone while the plain text is kept.
    static let richTypeIdentifiers: Set<String> = [PasteboardUTI.rtf, PasteboardUTI.html]

    /// The skip code for an over-ceiling text or image, chosen by where the payload came from (FR-007-06).
    static func limitCode(for origin: CaptureOrigin) -> ErrorCode {
        switch origin {
        case .pasteboard: .capLim001
        case .screenshotFile: .sspLim001
        case .shelfDrop: .shfLim001
        }
    }

    /// Applies every ceiling in one place. Failure means "skip the item"; warnings mean "stored, but trimmed".
    ///
    /// The ceiling goes into the error as `limitBytes`, the one context key `FlotsamStrings.message(for:)` reads for
    /// `{limit}`, so the Notice renders it with binary units (FR-007-06) without Storage owning any user-facing
    /// formatting. `byteSize` is a different quantity (a stored or available size) and never carries a ceiling.
    static func apply(to candidate: IngestCandidate) -> FlotsamResult<LimitedPayload> {
        func skip(_ ceiling: Int) -> FlotsamResult<LimitedPayload> {
            .failure(FlotsamError(
                limitCode(for: candidate.origin), "Payload over the ingest ceiling",
                context: [.limitBytes: .bytes(ceiling)]))
        }

        if let text = candidate.plainText, text.utf8.count > maxTextBytes { return skip(maxTextBytes) }

        var warnings: [FlotsamError] = []
        var kept: [PasteboardRepresentation] = []
        var droppedRich = 0
        for representation in candidate.representations {
            if richTypeIdentifiers.contains(representation.uti), representation.data.count > maxRichRepresentationBytes {
                droppedRich += 1
            } else {
                kept.append(representation)
            }
        }
        if droppedRich > 0 {
            warnings.append(FlotsamError(
                .capLim002, "Rich representation dropped; plain text kept",
                context: [.count: .int(droppedRich), .limitBytes: .bytes(maxRichRepresentationBytes)]))
        }

        if candidate.kind == .image || candidate.kind == .screenshot {
            let imageBytes = kept.reduce(0) { $0 + $1.data.count }
            if imageBytes > maxImageBytes { return skip(maxImageBytes) }
        }

        var members = candidate.members
        if members.count > maxBundleMembers {
            warnings.append(FlotsamError(
                .capLim003, "Bundle trimmed to the member ceiling",
                context: [.count: .int(members.count)]))
            members = Array(members.prefix(maxBundleMembers))
        }
        return .success(LimitedPayload(representations: kept, members: members, warnings: warnings))
    }
}
