import FlotsamBase
import Foundation

/// A file or folder held by reference as part of a file, folder or bundle item (FRD-001 FR-001-12).
public struct IngestMember: Sendable, Equatable {
    public let path: String
    public let bookmark: Data?
    public let isDirectory: Bool

    public init(path: String, bookmark: Data?, isDirectory: Bool) {
        self.path = path
        self.bookmark = bookmark
        self.isDirectory = isDirectory
    }
}

/// The immutable value every producer (clipboard capture, screenshot pickup, Shelf drop) hands to the ingest actor
/// (FR-007-05).
///
/// It lives in Storage because Storage may not import Payload (ADR-0001): Payload classifies a `CapturedPayload`
/// into one of these, and Storage never needs to know how. `contentKey` is computed by the producer from the raw
/// received bytes (FRD-001 FR-001-15) and is only compared here.
public struct IngestCandidate: Sendable, Equatable {
    public let kind: ItemKind
    public let contentKey: String
    /// The text of text-like kinds (text, richText, link, color, phone, email); nil otherwise (FR-007-03).
    public let plainText: String?
    /// Everything that becomes a blob: rich text and image bytes, as received. Plain text is never a representation.
    public let representations: [PasteboardRepresentation]
    public let members: [IngestMember]
    public let source: SourceApp?
    public let origin: CaptureOrigin
    /// When the copy happened. Screenshot pickup supplies the file's own date (FRD-002 FR-002-09).
    public let occurredAt: Date
    /// Screenshots only.
    public let originalPath: String?
    /// False only for screenshot backfill (FRD-002 FR-002-12), which is not a copy event: a `contentKey` match then
    /// leaves the existing item fully untouched instead of bumping it (FRD-001 FR-001-15 exception).
    public let countsAsCopy: Bool

    public init(
        kind: ItemKind, contentKey: String, plainText: String? = nil,
        representations: [PasteboardRepresentation] = [], members: [IngestMember] = [],
        source: SourceApp? = nil, origin: CaptureOrigin, occurredAt: Date, originalPath: String? = nil,
        countsAsCopy: Bool = true
    ) {
        self.kind = kind
        self.contentKey = contentKey
        self.plainText = plainText
        self.representations = representations
        self.members = members
        self.source = source
        self.origin = origin
        self.occurredAt = occurredAt
        self.originalPath = originalPath
        self.countsAsCopy = countsAsCopy
    }
}

public enum IngestOutcome: Sendable, Equatable {
    case created(UUID)
    case bumped(UUID)
    /// A candidate with `countsAsCopy == false` matched this item, which was left exactly as it was.
    case unchanged(UUID)
}

/// What ingest did, plus the conditions the caller should surface without the item having failed: a dropped rich
/// representation or trimmed bundle (`CAP-LIM-002`, `CAP-LIM-003`) and a budget Notice (`STO-LIM-001`).
public struct IngestResult: Sendable, Equatable {
    public let outcome: IngestOutcome
    public let warnings: [FlotsamError]
}
